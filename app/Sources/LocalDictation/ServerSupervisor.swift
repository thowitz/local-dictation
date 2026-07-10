import Darwin
import Foundation
import os

/// Spawns and supervises the Python realtime server process.
@MainActor
final class ServerSupervisor {
    enum State: Equatable, Sendable {
        case idle
        case launching
        case downloading(percent: Int?)
        case waitingForReady
        case running
        case restarting(ServerRestartStatus)
        case stopped
        case failed(ServerFailure)
    }

    enum TimeoutKind: Equatable, Sendable {
        case inactivity
        case absoluteCap
        /// Absolute download-active cap reached (download activity was observed).
        case stalledDownload
    }

    /// Why the controller asked the supervisor to stop the child.
    enum StopReason: Equatable, Sendable {
        case idleTimeout
        case applicationQuit
    }

    /// Injectable seams for deterministic tests.
    struct Dependencies: @unchecked Sendable {
        var resolveCommand: (AppConfig) -> Result<ServerLaunchCommand, ServerLaunchCommandResolver.ResolutionError>
        var healthProbe: (URL) async -> Bool
        var portProbe: (String, Int) -> PortProbeResult
        var makeProcess: ManagedProcessFactory
        var sleep: (Duration) async throws -> Void
        var now: () -> Date
        /// Total bytes of Hugging Face `*.incomplete` partial-download blobs on
        /// disk, or `nil` when none/unavailable. A *rising* value is disk-backed
        /// download liveness: piped tqdm/HF stays silent for minutes on a large
        /// safetensors shard, so output alone cannot tell a live download from a
        /// hung one — the growing blob can. Sampled every readiness poll.
        var downloadInFlightByteCount: () -> Int?

        static func production() -> Dependencies {
            Dependencies(
                resolveCommand: { $0.resolveServerLaunchCommand() },
                healthProbe: { url in
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.timeoutInterval = 2
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        return (response as? HTTPURLResponse)?.statusCode == 200
                    } catch {
                        return false
                    }
                },
                portProbe: { host, port in PortProbe.bind(host: host, port: port) },
                makeProcess: { url, args in FoundationManagedProcess(executableURL: url, arguments: args) },
                sleep: { duration in try await Task.sleep(for: duration) },
                now: { Date() },
                downloadInFlightByteCount: { HuggingFaceCacheProbe.inFlightIncompleteByteCount() }
            )
        }
    }

    private(set) var state: State = .idle {
        didSet {
            onStateChange?(state)
        }
    }

    var onStateChange: ((State) -> Void)?

    private let config: AppConfig
    private let policy: ServerSupervisorPolicy
    private let deps: Dependencies

    private var managed: (any ManagedProcess)?
    private var supervisionTask: Task<Void, Never>?
    /// Identity for the active supervision run; prevents a finishing cancelled
    /// task from clearing a newer `supervisionTask` after stop()+start().
    private var supervisionRunID = UUID()
    private var stoppingIntentionally = false
    private var intentionalStopReason: StopReason?
    /// Controller-facing intent: true while the speech runtime should be resident.
    private(set) var desiredRunning = false
    /// Reaps an intentionally stopped child before publishing `.stopped` or relaunching.
    private var reapingTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    private var stdoutPartial = ""
    private var stderrPartial = ""
    private var downloadPercent: Int?

    private var stderrCollector = BoundedStderrCollector()
    private var activity = StartupActivitySnapshot.empty
    private var currentCommand: ServerLaunchCommand?
    private var attemptStartedAt: Date?
    private var attemptNumber = 0
    private var becameHealthyAt: Date?
    private var lastTimeoutKind: TimeoutKind?

    init(
        config: AppConfig,
        policy: ServerSupervisorPolicy = .production,
        dependencies: Dependencies = .production()
    ) {
        self.config = config
        self.policy = policy
        self.deps = dependencies
    }

    func start() {
        desiredRunning = true
        // Already supervising — leave the current run alone.
        if supervisionTask != nil { return }
        // Intentional stop in flight: reap completion will relaunch once.
        if reapingTask != nil {
            stoppingIntentionally = false
            intentionalStopReason = nil
            if state == .stopped || state == .idle {
                transition(to: .launching)
            }
            return
        }

        beginSupervision()
    }

    func retry() {
        stop(reason: .applicationQuit)
        start()
    }

    func stop(reason: StopReason) {
        desiredRunning = false
        // Record intent before cancelling readiness or signalling the child.
        intentionalStopReason = reason
        stoppingIntentionally = true
        let stopGeneration = generation
        generation &+= 1
        // Invalidate so a still-finishing cancelled supervise() cannot clear a
        // newer task started by a subsequent start()/retry().
        supervisionRunID = UUID()
        supervisionTask?.cancel()
        supervisionTask = nil

        let child = managed
        // Detach callbacks so stale handlers cannot mutate state after the generation bump,
        // but retain `managed` until the child is confirmed gone.
        if let managed {
            managed.onStdout = nil
            managed.onStderr = nil
            managed.onTerminate = nil
        }
        // Unblock any parked EOF waiters immediately (stuck drain / inherited FDs).
        child?.forceFinishOutputDrain()

        guard let child else {
            finishIntentionalStop()
            return
        }

        if reapingTask != nil {
            return
        }

        reapingTask = Task { @MainActor [weak self] in
            guard let self else {
                if child.isRunning { child.forceKill() }
                return
            }
            await self.reapIntentionalStop(child: child, stopGeneration: stopGeneration)
        }
    }

    private func beginSupervision() {
        stoppingIntentionally = false
        intentionalStopReason = nil
        stderrCollector.reset()
        activity = .empty
        currentCommand = nil
        attemptNumber = 0
        becameHealthyAt = nil
        lastTimeoutKind = nil
        generation &+= 1
        transition(to: .launching)
        let runID = UUID()
        supervisionRunID = runID
        supervisionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.supervisionRunID == runID {
                    self.supervisionTask = nil
                }
            }
            await self.supervise()
        }
    }

    private func reapIntentionalStop(child: any ManagedProcess, stopGeneration: UInt64) async {
        defer { reapingTask = nil }

        if child.isRunning {
            child.terminate()
        }
        // Only wait out the grace window while the child is still alive.
        if child.isRunning {
            do {
                try await deps.sleep(policy.terminationGrace)
            } catch {
                if child.isRunning { child.forceKill() }
            }
            if child.isRunning {
                child.forceKill()
            }
        }

        // Confirm the child is gone before publishing stopped / relaunching.
        while child.isRunning {
            do {
                try await deps.sleep(policy.readinessPollInterval)
            } catch {
                if child.isRunning { child.forceKill() }
                break
            }
        }

        _ = stopGeneration
        clearProcess()
        finishIntentionalStop()
    }

    private func finishIntentionalStop() {
        let reason = intentionalStopReason
        intentionalStopReason = nil
        if desiredRunning {
            AppLog.server.info(
                "Intentional stop complete (reason=\(String(describing: reason), privacy: .public)); relaunching because desiredRunning"
            )
            beginSupervision()
        } else {
            stoppingIntentionally = false
            transition(to: .stopped)
            AppLog.server.info(
                "Intentional stop complete (reason=\(String(describing: reason), privacy: .public))"
            )
        }
    }

    // MARK: - Supervision loop

    private func supervise() async {
        // Note: supervisionTask cleared by start()'s Task defer (run-ID gated).

        if !(1...65535).contains(config.port) {
            guard !stoppingIntentionally else { return }
            transition(to: .failed(makeFailure(
                kind: .invalidPort,
                message: "Invalid port \(config.port); expected 1...65535."
            )))
            return
        }

        var consecutiveFailures = 0
        var latestExit: ServerExit?

        // Outer loop continues across attempts; per-attempt `generation` invalidates
        // stale callbacks without aborting the supervision task itself.
        while !stoppingIntentionally && !Task.isCancelled {
            let attemptGeneration = beginAttempt()
            guard isCurrent(attemptGeneration) else { return }

            transition(to: .launching)
            downloadPercent = nil
            activity = .empty
            becameHealthyAt = nil
            lastTimeoutKind = nil
            attemptNumber += 1
            stderrCollector.beginAttempt(attemptNumber)
            attemptStartedAt = deps.now()

            // Fresh command every attempt.
            let resolution = deps.resolveCommand(config)
            let command: ServerLaunchCommand
            switch resolution {
            case .success(let resolved):
                command = resolved
                currentCommand = command
            case .failure(let error):
                guard isCurrent(attemptGeneration) else { return }
                transition(to: .failed(failureFromResolution(error)))
                return
            }

            // Port preflight BEFORE creating the process.
            switch deps.portProbe("127.0.0.1", config.port) {
            case .available:
                break
            case .inUse:
                guard isCurrent(attemptGeneration) else { return }
                transition(to: .failed(makeFailure(
                    kind: .portInUse,
                    message: "Port \(config.port) already in use."
                )))
                return
            case .unavailable:
                guard isCurrent(attemptGeneration) else { return }
                transition(to: .failed(makeFailure(
                    kind: .portUnavailable,
                    message: "Port \(config.port) is unavailable."
                )))
                return
            }

            do {
                try spawn(command: command, generation: attemptGeneration)
            } catch {
                guard isCurrent(attemptGeneration) else { return }
                clearProcess()
                transition(to: .failed(failureFromSpawnError(error)))
                return
            }

            transition(to: .waitingForReady)
            let outcome = await waitForReadiness(generation: attemptGeneration)

            switch outcome {
            case .ready:
                guard isCurrent(attemptGeneration) else { return }
                becameHealthyAt = deps.now()
                transition(to: .running)
                await waitForExit(generation: attemptGeneration)
                await drainOutput(generation: attemptGeneration)
                guard isCurrent(attemptGeneration), !stoppingIntentionally else { return }

                if let sentinel = detectPortSentinel() {
                    latestExit = makeExit(reason: .exited(status: managed?.exit.flatMap {
                        if case .exited(let s) = $0 { return s }
                        return nil
                    } ?? 1))
                    clearProcess()
                    transition(to: .failed(makeFailure(
                        kind: .portInUse,
                        message: sentinel,
                        exit: latestExit
                    )))
                    return
                }

                consecutiveFailures = nextFailureCount(
                    current: consecutiveFailures,
                    healthySince: becameHealthyAt
                )
                latestExit = makeExit(reason: exitReasonFromManaged())

            case .exited:
                await drainOutput(generation: attemptGeneration)
                guard isCurrent(attemptGeneration), !stoppingIntentionally else { return }

                if let sentinel = detectPortSentinel() {
                    latestExit = makeExit(reason: exitReasonFromManaged())
                    clearProcess()
                    transition(to: .failed(makeFailure(
                        kind: .portInUse,
                        message: sentinel,
                        exit: latestExit
                    )))
                    return
                }

                consecutiveFailures += 1
                latestExit = makeExit(reason: exitReasonFromManaged())

            case .timedOut(let kind):
                lastTimeoutKind = kind
                await escalateTermination(forGeneration: attemptGeneration)
                await drainOutput(generation: attemptGeneration)
                guard isCurrent(attemptGeneration), !stoppingIntentionally else { return }
                clearProcess()
                let message: String
                switch kind {
                case .inactivity:
                    message = "Server readiness timed out: no output/health for \(formatDuration(policy.inactivityTimeout))."
                case .absoluteCap:
                    message = "Server readiness timed out: absolute startup cap \(formatDuration(policy.absoluteStartupCap)) reached."
                case .stalledDownload:
                    message = "Server readiness timed out: download-active startup cap \(formatDuration(policy.downloadActiveStartupCap)) reached (stalled download)."
                }
                transition(to: .failed(makeFailure(
                    kind: .readinessTimedOut,
                    message: message,
                    exit: makeExit(reason: .timedOut)
                )))
                return

            case .cancelled:
                return
            }

            clearProcess()
            guard isCurrent(attemptGeneration), !stoppingIntentionally else { return }

            if consecutiveFailures >= policy.maxConsecutiveFailures {
                let exit = latestExit ?? makeExit(reason: .unknown)
                transition(to: .failed(makeFailure(
                    kind: .consecutiveExits,
                    message: "Server exited \(consecutiveFailures) consecutive times.",
                    exit: exit
                )))
                return
            }

            let backoff = policy.backoff(forAttempt: consecutiveFailures)
            let exit = latestExit ?? makeExit(reason: .unknown)
            let status = ServerRestartStatus(
                attempt: consecutiveFailures,
                maxAttempts: policy.maxConsecutiveFailures,
                backoff: backoff,
                latestExit: exit
            )
            transition(to: .restarting(status))
            do {
                try await gatedSleep(backoff, generation: attemptGeneration)
            } catch {
                return
            }
        }
    }

    private enum ReadinessOutcome {
        case ready
        case exited
        case timedOut(TimeoutKind)
        case cancelled
    }

    private func waitForReadiness(generation attemptGeneration: UInt64) async -> ReadinessOutcome {
        let started = deps.now()
        var lastActivity = started
        // Last on-disk `*.incomplete` byte count; only a strict increase counts as
        // liveness (see below). `nil` until the first successful sample.
        var previousDownloadBytes: Int?

        while isCurrent(attemptGeneration) && !stoppingIntentionally && !Task.isCancelled {
            if managed?.isRunning != true {
                return .exited
            }

            // ONLY HTTP 200 transitions to running — markers are diagnostic only.
            if await gatedHealth(generation: attemptGeneration) {
                return .ready
            }

            let now = deps.now()
            if let activityAt = activity.lastOutputAt, activityAt > lastActivity {
                lastActivity = activityAt
            }

            // Disk-backed liveness: a live model download advances its `*.incomplete`
            // blob on disk even when piped tqdm/HF emits nothing for minutes. A
            // *rising* byte count refreshes the inactivity timer and marks the attempt
            // download-active (the longer cap applies); a flat count (true stall)
            // does neither, so a genuinely hung download still times out.
            if let bytes = deps.downloadInFlightByteCount() {
                if let previous = previousDownloadBytes, bytes > previous {
                    lastActivity = now
                    activity.lastDownloadProgressAt = now
                    switch state {
                    case .launching, .waitingForReady, .downloading:
                        transition(to: .downloading(percent: downloadPercent))
                    default:
                        break
                    }
                }
                previousDownloadBytes = bytes
            }

            let downloadActive = activity.hasDownloadActivity
            let absoluteCap = downloadActive
                ? policy.downloadActiveStartupCap
                : policy.absoluteStartupCap
            if now.timeIntervalSince(started) >= durationSeconds(absoluteCap) {
                return .timedOut(downloadActive ? .stalledDownload : .absoluteCap)
            }
            if now.timeIntervalSince(lastActivity) >= durationSeconds(policy.inactivityTimeout) {
                return .timedOut(.inactivity)
            }

            do {
                try await gatedSleep(policy.readinessPollInterval, generation: attemptGeneration)
            } catch {
                return .cancelled
            }

            if managed?.isRunning != true {
                return .exited
            }
        }
        return .cancelled
    }

    private func waitForExit(generation attemptGeneration: UInt64) async {
        // Poll so cancellation / generation bumps cannot leak a continuation.
        while isCurrent(attemptGeneration) && !stoppingIntentionally && !Task.isCancelled {
            if managed?.isRunning != true { return }
            do {
                try await gatedSleep(policy.readinessPollInterval, generation: attemptGeneration)
            } catch {
                return
            }
        }
    }

    // MARK: - Spawn / terminate / drain

    private func spawn(command: ServerLaunchCommand, generation attemptGeneration: UInt64) throws {
        clearProcess()

        let arguments = command.processArguments(
            port: config.port,
            parentPID: ProcessInfo.processInfo.processIdentifier,
            model: config.model
        )
        let process = deps.makeProcess(command.executableURL, arguments)
        // ManagedProcess is @MainActor; keep handlers synchronous so activity
        // timestamps land before the next readiness poll / fake-clock advance.
        process.onStdout = { [weak self] data in
            self?.handleOutput(data: data, isStderr: false, generation: attemptGeneration)
        }
        process.onStderr = { [weak self] data in
            self?.handleOutput(data: data, isStderr: true, generation: attemptGeneration)
        }
        // Termination observation is installed inside launch() before run().
        process.onTerminate = { [weak self] in
            guard let self, self.isCurrent(attemptGeneration) else { return }
            // Exit is observed by waitForExit / readiness loop.
        }

        do {
            try process.launch()
        } catch {
            process.onStdout = nil
            process.onStderr = nil
            process.onTerminate = nil
            throw SpawnLaunchError(underlying: error, command: command)
        }

        self.managed = process
        AppLog.server.info(
            "Launched server source=\(command.source.rawValue, privacy: .public) pid=\(process.processIdentifier) cmd=\(command.displayCommandLine, privacy: .public) gen=\(attemptGeneration)"
        )
    }

    private func escalateTermination(forGeneration attemptGeneration: UInt64) async {
        guard let managed else { return }
        if managed.isRunning {
            managed.terminate()
            do {
                try await gatedSleep(policy.terminationGrace, generation: attemptGeneration)
            } catch {
                return
            }
        }
        if isCurrent(attemptGeneration), managed.isRunning {
            managed.forceKill()
        }
        // Brief yield so termination handler can fire.
        do {
            try await gatedSleep(.milliseconds(10), generation: attemptGeneration)
        } catch {
            return
        }
    }

    private func drainOutput(generation attemptGeneration: UInt64) async {
        guard isCurrent(attemptGeneration), let managed else {
            stderrCollector.flushEOF()
            return
        }

        // Bound the drain: inherited pipe write-ends must not park forever.
        // Poll on the MainActor (no TaskGroup) so isolation stays simple.
        let started = deps.now()
        let limit = durationSeconds(policy.outputDrainTimeout)
        while isCurrent(attemptGeneration) && !stoppingIntentionally && !Task.isCancelled {
            if managed.hasReachedOutputEOF { break }
            if deps.now().timeIntervalSince(started) >= limit {
                managed.forceFinishOutputDrain()
                break
            }
            do {
                try await gatedSleep(policy.readinessPollInterval, generation: attemptGeneration)
            } catch {
                managed.forceFinishOutputDrain()
                break
            }
        }
        if !managed.hasReachedOutputEOF {
            managed.forceFinishOutputDrain()
        }

        guard isCurrent(attemptGeneration) else { return }
        stderrCollector.flushEOF()
    }

    // MARK: - Output

    private func handleOutput(data: Data, isStderr: Bool, generation attemptGeneration: UInt64) {
        guard isCurrent(attemptGeneration), !stoppingIntentionally else { return }

        if isStderr {
            stderrCollector.append(data: data)
        }

        let text = String(decoding: data, as: UTF8.self)
        // Any non-empty output refreshes inactivity liveness; download UI is separate.
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activity.lastOutputAt = deps.now()
        }

        var buffer = (isStderr ? stderrPartial : stdoutPartial) + text
        let endsWithNewline = buffer.hasSuffix("\n") || buffer.hasSuffix("\r")
        var pieces = buffer.components(separatedBy: CharacterSet(charactersIn: "\n\r"))

        if endsWithNewline {
            buffer = ""
            if pieces.last?.isEmpty == true {
                pieces.removeLast()
            }
        } else {
            buffer = pieces.popLast() ?? ""
        }

        if isStderr {
            stderrPartial = buffer
        } else {
            stdoutPartial = buffer
        }

        for piece in pieces {
            handleLine(piece, isStderr: isStderr, generation: attemptGeneration)
        }
        if isStderr, !buffer.isEmpty {
            noteDownloadProgress(in: buffer, generation: attemptGeneration)
        }

        // Late port sentinel while waiting for readiness short-circuits via exit path;
        // also terminate promptly if we see it in stderr mid-flight.
        if isStderr, detectPortSentinel() != nil, managed?.isRunning == true {
            managed?.terminate()
        }
    }

    private func handleLine(_ raw: String, isStderr: Bool, generation attemptGeneration: UInt64) {
        guard isCurrent(attemptGeneration) else { return }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        if isStderr {
            AppLog.server.debug("[stderr] \(line, privacy: .public)")
            noteDownloadProgress(in: line, generation: attemptGeneration)
        } else {
            AppLog.server.info("[stdout] \(line, privacy: .public)")
            // Markers (e.g. VOXMLX_READY) are diagnostic only — never readiness.
        }
    }

    private func noteDownloadProgress(in line: String, generation attemptGeneration: UInt64) {
        guard isCurrent(attemptGeneration) else { return }
        let parsed = DownloadProgressParser.parse(line)
        guard parsed.isDownloadProgress else { return }

        let now = deps.now()
        activity.lastDownloadProgressAt = now
        activity.lastOutputAt = now
        if let percent = parsed.percent {
            activity.downloadPercent = percent
            activity.downloadPercentUnknown = false
            downloadPercent = percent
        } else if parsed.percentUnknown {
            activity.downloadPercentUnknown = true
            downloadPercent = nil
        }

        switch state {
        case .waitingForReady, .launching, .downloading:
            transition(to: .downloading(percent: downloadPercent))
        default:
            break
        }
    }

    // MARK: - Helpers

    private func beginAttempt() -> UInt64 {
        generation &+= 1
        return generation
    }

    private func isCurrent(_ attemptGeneration: UInt64) -> Bool {
        !stoppingIntentionally && generation == attemptGeneration
    }

    private func gatedSleep(_ duration: Duration, generation attemptGeneration: UInt64) async throws {
        guard isCurrent(attemptGeneration) else {
            throw CancellationError()
        }
        try await deps.sleep(duration)
        guard isCurrent(attemptGeneration) else {
            throw CancellationError()
        }
    }

    private func gatedHealth(generation attemptGeneration: UInt64) async -> Bool {
        guard isCurrent(attemptGeneration) else { return false }
        let ok = await deps.healthProbe(config.healthURL)
        guard isCurrent(attemptGeneration) else { return false }
        return ok
    }

    private func nextFailureCount(current: Int, healthySince: Date?) -> Int {
        guard let healthySince else { return current + 1 }
        let elapsed = deps.now().timeIntervalSince(healthySince)
        if elapsed >= durationSeconds(policy.healthyStabilityWindow) {
            return 1
        }
        return current + 1
    }

    private func detectPortSentinel() -> String? {
        // Only scan the current attempt's segment so prior-attempt noise cannot
        // short-circuit the retry budget.
        let segment = stderrCollector.currentAttemptSegment().lowercased()
        if segment.contains("local_dictation_fatal") && segment.contains("port_in_use") {
            return "Child reported LOCAL_DICTATION_FATAL kind=port_in_use."
        }
        if segment.contains("eaddrinuse") || segment.contains("address already in use") {
            return "Child reported address already in use."
        }
        return nil
    }

    private func clearProcess() {
        if let managed {
            managed.onStdout = nil
            managed.onStderr = nil
            managed.onTerminate = nil
        }
        managed = nil
        stdoutPartial = ""
        stderrPartial = ""
        // Do NOT reset stderrCollector — retain across attempts.
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        AppLog.server.info("state → \(String(describing: newState), privacy: .public)")
    }

    private func makeExit(reason: ServerExit.Reason) -> ServerExit {
        let started = attemptStartedAt ?? deps.now()
        let duration = deps.now().timeIntervalSince(started)
        return ServerExit(
            reason: reason,
            runDuration: .seconds(duration),
            command: currentCommand,
            activity: activity,
            stderrTail: stderrCollector.tail(),
            port: config.port
        )
    }

    private func exitReasonFromManaged() -> ServerExit.Reason {
        guard let exit = managed?.exit else { return .unknown }
        switch exit {
        case .exited(let status):
            return .exited(status: status)
        case .signaled(let signal):
            return .signaled(signal: signal)
        }
    }

    private func makeFailure(
        kind: ServerFailure.Kind,
        message: String?,
        exit: ServerExit? = nil
    ) -> ServerFailure {
        var msg = message
        if kind == .readinessTimedOut, let timeout = lastTimeoutKind {
            let suffix: String
            switch timeout {
            case .inactivity:
                suffix = "timeoutReason: inactivity"
            case .absoluteCap:
                suffix = "timeoutReason: absoluteCap"
            case .stalledDownload:
                suffix = "timeoutReason: stalledDownload"
            }
            if let existing = msg {
                msg = existing + " (\(suffix))"
            } else {
                msg = suffix
            }
        }
        return ServerFailure(
            kind: kind,
            command: currentCommand ?? exit?.command,
            port: config.port,
            exit: exit,
            activity: exit?.activity ?? activity,
            stderrTail: exit?.stderrTail ?? stderrCollector.tail(),
            underlyingMessage: msg
        )
    }

    private func failureFromResolution(
        _ error: ServerLaunchCommandResolver.ResolutionError
    ) -> ServerFailure {
        switch error {
        case .overrideMissing, .noCandidateFound, .overrideNotAbsolute:
            return makeFailure(kind: .commandNotFound, message: error.description)
        case .overrideNotExecutable:
            return makeFailure(kind: .commandNotExecutable, message: error.description)
        }
    }

    private func failureFromSpawnError(_ error: Error) -> ServerFailure {
        if let launch = error as? SpawnLaunchError {
            currentCommand = launch.command
            return makeFailure(
                kind: .launchFailed,
                message: launch.underlying.localizedDescription,
                exit: makeExit(reason: .launchFailed(message: launch.underlying.localizedDescription))
            )
        }
        return makeFailure(kind: .launchFailed, message: error.localizedDescription)
    }

    private func durationSeconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    private func formatDuration(_ duration: Duration) -> String {
        let seconds = durationSeconds(duration)
        if seconds >= 60 {
            return String(format: "%.0f minutes", seconds / 60)
        }
        return String(format: "%.0f seconds", seconds)
    }
}

private struct SpawnLaunchError: Error {
    let underlying: Error
    let command: ServerLaunchCommand
}

/// Best-effort read of the Hugging Face hub cache for an in-flight download.
///
/// `snapshot_download` streams each blob into a `<hub>/models--*/blobs/<sha>.incomplete`
/// sidecar and renames it on completion, so the summed size of those files rises
/// monotonically while bytes land — even when piped tqdm/HF output goes quiet on a
/// large safetensors shard. The readiness watchdog treats a *rising* count as
/// liveness. This never fabricates liveness: any absence or error yields `nil`.
private enum HuggingFaceCacheProbe {
    /// Total bytes of all `*.incomplete` blobs in the hub cache, or `nil` when the
    /// cache is missing, unreadable, or holds no partial download. Kept cheap for
    /// the ~400 ms readiness poll: scan only each repo's `blobs` dir (there are
    /// ~0–1 `*.incomplete` files at a time), never the whole cache tree.
    static func inFlightIncompleteByteCount() -> Int? {
        guard let hub = hubCacheURL() else { return nil }
        let fm = FileManager.default
        guard let repos = try? fm.contentsOfDirectory(
            at: hub,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var total = 0
        var sawIncomplete = false
        for repo in repos {
            let blobs = repo.appendingPathComponent("blobs", isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: blobs,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for entry in entries where entry.pathExtension == "incomplete" {
                sawIncomplete = true
                let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                total += size
            }
        }
        return sawIncomplete ? total : nil
    }

    /// Resolve the hub cache dir the way `huggingface_hub` does, honoring env
    /// overrides in precedence order: `HF_HUB_CACHE`, else `HF_HOME`/hub, else
    /// `XDG_CACHE_HOME`/huggingface/hub, else `~/.cache/huggingface/hub`. The
    /// child inherits our environment, so reading it here matches the child's cache.
    static func hubCacheURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty else { return nil }
            return raw
        }

        if let hubCache = value("HF_HUB_CACHE") {
            return URL(fileURLWithPath: hubCache, isDirectory: true)
        }
        if let hfHome = value("HF_HOME") {
            return URL(fileURLWithPath: hfHome, isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
        }
        if let xdg = value("XDG_CACHE_HOME") {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
    }
}
