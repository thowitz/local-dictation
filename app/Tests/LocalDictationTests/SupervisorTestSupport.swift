import Darwin
import Foundation
@testable import LocalDictation

// MARK: - Fake clock

@MainActor
final class FakeClock {
    private(set) var now: Date
    private var sleepers: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []

    init(start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.now = start
    }

    func current() -> Date { now }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        let deadline = now.addingTimeInterval(seconds)
        if deadline <= now {
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                sleepers.append((deadline, cont))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.failAllSleepers(CancellationError())
            }
        }
    }

    func advance(by duration: Duration) {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        now = now.addingTimeInterval(seconds)
        resumeDueSleepers()
    }

    func advance(to date: Date) {
        if date > now {
            now = date
            resumeDueSleepers()
        }
    }

    private func resumeDueSleepers() {
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    private func failAllSleepers(_ error: Error) {
        let pending = sleepers
        sleepers.removeAll()
        for sleeper in pending {
            sleeper.continuation.resume(throwing: error)
        }
    }
}

// MARK: - Scripted fake process

@MainActor
final class FakeManagedProcess: ManagedProcess {
    struct Script {
        var stdoutChunks: [Data]
        var stderrChunks: [Data]
        var exitAfterLaunch: ManagedProcessExit?
        var launchError: Error?
        /// Emit output immediately on launch (before returning from launch()).
        var emitOnLaunch: Bool
        /// Delay exit until `completeExit()` / terminate / forceKill.
        var holdExit: Bool
        /// If true, never signal pipe EOF (simulates inherited write-end / stuck drain).
        var neverEOF: Bool
        /// If true, `isRunning` clears before `exit` becomes readable via the stored
        /// publication path — mirrors Foundation's terminationHandler MainActor hop.
        var deferExitPublication: Bool

        init(
            stdoutChunks: [Data] = [],
            stderrChunks: [Data] = [],
            exitAfterLaunch: ManagedProcessExit? = .exited(status: 0),
            launchError: Error? = nil,
            emitOnLaunch: Bool = true,
            holdExit: Bool = false,
            neverEOF: Bool = false,
            deferExitPublication: Bool = false
        ) {
            self.stdoutChunks = stdoutChunks
            self.stderrChunks = stderrChunks
            self.exitAfterLaunch = exitAfterLaunch
            self.launchError = launchError
            self.emitOnLaunch = emitOnLaunch
            self.holdExit = holdExit
            self.neverEOF = neverEOF
            self.deferExitPublication = deferExitPublication
        }
    }

    private let script: Script
    private(set) var launched = false
    private(set) var terminateCount = 0
    private(set) var forceKillCount = 0
    private(set) var processIdentifier: Int32 = 4242
    private(set) var isRunning = false
    /// Termination facts recorded as soon as the process stops (like Process.terminationStatus).
    private var recordedTermination: ManagedProcessExit?
    /// Lazily published exit (old buggy path); only set after a MainActor hop when deferred.
    private var publishedExit: ManagedProcessExit?
    private var stdoutEOF = false
    private var stderrEOF = false
    private var eofWaiters: [CheckedContinuation<Void, any Error>] = []
    private(set) var forceFinishCount = 0

    var onStdout: ((Data) -> Void)?
    var onStderr: ((Data) -> Void)?
    var onTerminate: (() -> Void)?

    var hasReachedOutputEOF: Bool { stdoutEOF && stderrEOF }

    /// When true (default after the Foundation fix), `exit` reads recorded termination
    /// as soon as `!isRunning`. When false with `deferExitPublication`, mirrors the
    /// old race so a regression test can prove the bug.
    var useRecordedExitWhenStopped = true

    var exit: ManagedProcessExit? {
        guard !isRunning else { return nil }
        if useRecordedExitWhenStopped || !script.deferExitPublication {
            return recordedTermination
        }
        return publishedExit
    }

    /// Shared factory state for tests that create multiple processes.
    final class Factory: @unchecked Sendable {
        @MainActor var scripts: [Script]
        @MainActor private(set) var created: [FakeManagedProcess] = []
        @MainActor var nextPID: Int32 = 5000

        init(scripts: [Script]) {
            self.scripts = scripts
        }

        @MainActor
        func make(executableURL: URL, arguments: [String]) -> FakeManagedProcess {
            let script = scripts.isEmpty ? Script(holdExit: true) : scripts.removeFirst()
            let process = FakeManagedProcess(script: script)
            process.processIdentifier = nextPID
            nextPID += 1
            created.append(process)
            return process
        }
    }

    init(script: Script) {
        self.script = script
    }

    func launch() throws {
        if let error = script.launchError {
            throw error
        }
        launched = true
        isRunning = true

        if script.emitOnLaunch {
            for chunk in script.stdoutChunks {
                onStdout?(chunk)
            }
            for chunk in script.stderrChunks {
                onStderr?(chunk)
            }
            if !script.neverEOF {
                markOutputEOF()
            }
        }

        if !script.holdExit, let exit = script.exitAfterLaunch {
            completeExit(exit)
        }
    }

    func emitStdout(_ text: String) {
        onStdout?(Data(text.utf8))
    }

    func emitStderr(_ text: String) {
        onStderr?(Data(text.utf8))
    }

    func markOutputEOF() {
        stdoutEOF = true
        stderrEOF = true
        resumeEOFWaiters()
    }

    /// Detach readers and unblock any parked EOF waiters (drain timeout / stop).
    func forceFinishOutputDrain() {
        forceFinishCount += 1
        markOutputEOF()
    }

    func completeExit(_ exit: ManagedProcessExit) {
        guard recordedTermination == nil else { return }
        recordedTermination = exit
        // Clear running first (Foundation does this before the MainActor handler runs).
        isRunning = false

        if script.deferExitPublication {
            // Old buggy path: exit only becomes readable after a MainActor Task hop.
            publishedExit = nil
            onTerminate?()
            Task { @MainActor [weak self] in
                self?.publishedExit = exit
            }
        } else {
            publishedExit = exit
            onTerminate?()
        }

        if !script.neverEOF, (!stdoutEOF || !stderrEOF) {
            markOutputEOF()
        }
    }

    func terminate() {
        terminateCount += 1
        if isRunning {
            completeExit(.signaled(signal: SIGTERM))
        }
    }

    func forceKill() {
        forceKillCount += 1
        if isRunning {
            completeExit(.signaled(signal: SIGKILL))
        }
    }

    func waitForOutputEOF() async {
        if stdoutEOF && stderrEOF { return }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                    if self.stdoutEOF && self.stderrEOF {
                        cont.resume()
                    } else {
                        self.eofWaiters.append(cont)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.failEOFWaiters(CancellationError())
                }
            }
        } catch {
            // Cancelled / force-finished — treat as drain complete.
        }
    }

    private func resumeEOFWaiters() {
        let waiters = eofWaiters
        eofWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func failEOFWaiters(_ error: Error) {
        let waiters = eofWaiters
        eofWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }
}

// MARK: - Supervisor test harness

/// Mutable knobs shared with dependency closures (avoids capturing `self` before init).
@MainActor
final class SupervisorHarnessControls {
    var healthOK = false
    var portResult: PortProbeResult = .available
    var resolveResult: Result<ServerLaunchCommand, ServerLaunchCommandResolver.ResolutionError>
    let clock: FakeClock
    let factory: FakeManagedProcess.Factory

    init(
        resolveResult: Result<ServerLaunchCommand, ServerLaunchCommandResolver.ResolutionError>,
        clock: FakeClock,
        factory: FakeManagedProcess.Factory
    ) {
        self.resolveResult = resolveResult
        self.clock = clock
        self.factory = factory
    }
}

@MainActor
final class SupervisorHarness {
    let controls: SupervisorHarnessControls
    let supervisor: ServerSupervisor
    private(set) var states: [ServerSupervisor.State] = []

    var clock: FakeClock { controls.clock }
    var factory: FakeManagedProcess.Factory { controls.factory }
    var healthOK: Bool {
        get { controls.healthOK }
        set { controls.healthOK = newValue }
    }
    var portResult: PortProbeResult {
        get { controls.portResult }
        set { controls.portResult = newValue }
    }
    var resolveResult: Result<ServerLaunchCommand, ServerLaunchCommandResolver.ResolutionError> {
        get { controls.resolveResult }
        set { controls.resolveResult = newValue }
    }

    init(
        config: AppConfig = AppConfig(port: 8471),
        policy: ServerSupervisorPolicy,
        scripts: [FakeManagedProcess.Script],
        command: ServerLaunchCommand? = nil
    ) {
        let clock = FakeClock()
        let factory = FakeManagedProcess.Factory(scripts: scripts)
        let defaultCommand = command ?? ServerLaunchCommand(
            executableURL: URL(fileURLWithPath: "/tmp/fake-serve"),
            argumentPrefix: [],
            source: .development
        )
        let controls = SupervisorHarnessControls(
            resolveResult: .success(defaultCommand),
            clock: clock,
            factory: factory
        )
        self.controls = controls

        let deps = ServerSupervisor.Dependencies(
            resolveCommand: { _ in controls.resolveResult },
            healthProbe: { _ in controls.healthOK },
            portProbe: { _, _ in controls.portResult },
            makeProcess: { url, args in
                controls.factory.make(executableURL: url, arguments: args)
            },
            sleep: { duration in
                try await controls.clock.sleep(duration)
            },
            now: { controls.clock.current() }
        )

        self.supervisor = ServerSupervisor(config: config, policy: policy, dependencies: deps)
        self.supervisor.onStateChange = { [weak self] state in
            self?.states.append(state)
        }
    }

    func start() {
        supervisor.start()
    }

    func stop() {
        supervisor.stop()
    }

    /// Pump the cooperative scheduler and advance the fake clock.
    func pump(advance duration: Duration = .milliseconds(0), times: Int = 1) async {
        for _ in 0..<times {
            await Task.yield()
            if duration != .zero {
                clock.advance(by: duration)
            }
            await Task.yield()
        }
    }

    func waitUntil(
        timeoutAdvances: Int = 200,
        advance: Duration = .milliseconds(50),
        _ predicate: () -> Bool
    ) async {
        for _ in 0..<timeoutAdvances {
            if predicate() { return }
            await pump(advance: advance)
        }
    }
}

extension ServerSupervisorPolicy {
    /// Short timeouts for unit tests.
    static let test = ServerSupervisorPolicy(
        maxConsecutiveFailures: 5,
        readinessPollInterval: .milliseconds(10),
        inactivityTimeout: .milliseconds(100),
        absoluteStartupCap: .milliseconds(500),
        terminationGrace: .milliseconds(10),
        healthyStabilityWindow: .milliseconds(200),
        backoffBaseSeconds: 0.01,
        backoffCapSeconds: 0.05,
        outputDrainTimeout: .milliseconds(50)
    )
}
