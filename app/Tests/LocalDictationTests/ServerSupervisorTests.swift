import Darwin
import Foundation
import Testing
@testable import LocalDictation

@Suite("ServerSupervisor")
@MainActor
struct ServerSupervisorTests {

    // MARK: - Helpers

    private func failures(_ h: SupervisorHarness) -> [ServerFailure] {
        h.states.compactMap {
            if case .failed(let f) = $0 { return f }
            return nil
        }
    }

    private func restartStatuses(_ h: SupervisorHarness) -> [ServerRestartStatus] {
        h.states.compactMap {
            if case .restarting(let s) = $0 { return s }
            return nil
        }
    }

    // MARK: - Launch / readiness

    @Test("invalid launch throw → launchFailed, no retry, no leaked child")
    func launchFailedNoRetry() async {
        let scripts = [
            FakeManagedProcess.Script(
                launchError: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            ),
            // Would be used if supervisor incorrectly retried.
            FakeManagedProcess.Script(holdExit: true),
        ]
        let h = SupervisorHarness(policy: .test, scripts: scripts)
        h.start()
        await h.waitUntil { !self.failures(h).isEmpty }

        #expect(failures(h).map(\.kind) == [.launchFailed])
        #expect(h.factory.created.count == 1)
        #expect(!h.states.contains { if case .restarting = $0 { return true }; return false })
        #expect(h.supervisor.state == .failed(failures(h)[0]))
    }

    @Test("VOXMLX_READY alone does not become running; only HTTP 200 does")
    func healthOnlyReadiness() async {
        let scripts = [
            FakeManagedProcess.Script(
                stdoutChunks: [Data("VOXMLX_READY port=8471\n".utf8)],
                exitAfterLaunch: nil,
                holdExit: true
            )
        ]
        var policy = ServerSupervisorPolicy.test
        policy.inactivityTimeout = .milliseconds(200)
        policy.absoluteStartupCap = .milliseconds(400)
        let h = SupervisorHarness(policy: policy, scripts: scripts)
        h.healthOK = false
        h.start()

        await h.waitUntil {
            self.failures(h).contains { $0.kind == .readinessTimedOut }
        }

        #expect(!h.states.contains(.running))
        #expect(failures(h).contains { $0.kind == .readinessTimedOut })

        // Separate run: health 200 → running.
        let scripts2 = [
            FakeManagedProcess.Script(
                stdoutChunks: [Data("booting\n".utf8)],
                exitAfterLaunch: nil,
                holdExit: true
            )
        ]
        let h2 = SupervisorHarness(policy: .test, scripts: scripts2)
        h2.healthOK = true
        h2.start()
        await h2.waitUntil { h2.states.contains(.running) }
        #expect(h2.states.contains(.running))
    }

    // MARK: - Timeouts

    @Test("silent sleeping command → inactivity timeout, terminate + drain, child gone")
    func inactivityTimeout() async {
        let scripts = [
            FakeManagedProcess.Script(
                exitAfterLaunch: nil,
                holdExit: true
            )
        ]
        var policy = ServerSupervisorPolicy.test
        policy.inactivityTimeout = .milliseconds(80)
        policy.absoluteStartupCap = .seconds(30)
        let h = SupervisorHarness(policy: policy, scripts: scripts)
        h.healthOK = false
        h.start()

        await h.waitUntil {
            self.failures(h).contains { $0.kind == .readinessTimedOut }
        }

        let failure = failures(h)[0]
        #expect(failure.kind == .readinessTimedOut)
        #expect(failure.underlyingMessage?.contains("inactivity") == true)
        #expect(h.factory.created.first?.terminateCount ?? 0 >= 1)
        #expect(h.factory.created.first?.isRunning == false)
    }

    @Test("progress survives inactivity windows; times out after activity stops")
    func progressSurvivesThenInactivity() async {
        let scripts = [
            FakeManagedProcess.Script(
                exitAfterLaunch: nil,
                emitOnLaunch: false,
                holdExit: true
            )
        ]
        var policy = ServerSupervisorPolicy.test
        policy.inactivityTimeout = .milliseconds(100)
        policy.absoluteStartupCap = .seconds(30)
        policy.downloadActiveStartupCap = .seconds(60)
        policy.readinessPollInterval = .milliseconds(20)
        let h = SupervisorHarness(policy: policy, scripts: scripts)
        h.healthOK = false
        h.start()
        await h.waitUntil { h.factory.created.first != nil }

        // Survive several inactivity windows with recognized download progress.
        // Emit, then advance less than the inactivity window so liveness refreshes.
        for i in 0..<8 {
            h.factory.created.first?.emitStderr(
                "downloading: \(i * 10)%| 1.2MB/s | 10s left\n"
            )
            await h.pump(advance: .milliseconds(40), times: 1)
            #expect(
                failures(h).isEmpty,
                "should still be alive while progress continues (i=\(i))"
            )
        }
        #expect(h.states.contains { if case .downloading = $0 { return true }; return false })
        #expect(!h.states.contains(.running), "health remains the only ready transition")

        // Stop emitting; inactivity should fire (not absolute / stalled download).
        await h.waitUntil {
            self.failures(h).contains { $0.kind == .readinessTimedOut }
        }
        #expect(failures(h)[0].underlyingMessage?.contains("inactivity") == true)
        #expect(failures(h)[0].underlyingMessage?.contains("absoluteCap") != true)
        #expect(failures(h)[0].underlyingMessage?.contains("stalledDownload") != true)
    }

    @Test("absolute cap ends noisy-but-unhealthy command despite continuous output")
    func absoluteCapWithContinuousProgress() async {
        let scripts = [
            FakeManagedProcess.Script(
                exitAfterLaunch: nil,
                emitOnLaunch: false,
                holdExit: true
            )
        ]
        var policy = ServerSupervisorPolicy.test
        // No download activity — ordinary absolute cap applies.
        policy.inactivityTimeout = .milliseconds(500)
        policy.absoluteStartupCap = .milliseconds(200)
        policy.downloadActiveStartupCap = .seconds(30)
        policy.readinessPollInterval = .milliseconds(20)
        let h = SupervisorHarness(policy: policy, scripts: scripts)
        h.healthOK = false
        h.start()
        await h.waitUntil { h.factory.created.first != nil }

        for _ in 0..<12 {
            // Non-download noise keeps inactivity alive but does not extend the cap.
            h.factory.created.first?.emitStderr("still loading weights…\n")
            await h.pump(advance: .milliseconds(30), times: 2)
            if failures(h).contains(where: { $0.kind == .readinessTimedOut }) {
                break
            }
        }

        await h.waitUntil {
            self.failures(h).contains { $0.kind == .readinessTimedOut }
        }
        #expect(failures(h)[0].underlyingMessage?.contains("absoluteCap") == true)
        #expect(failures(h)[0].underlyingMessage?.contains("stalledDownload") != true)
    }

    @Test("download activity extends absolute window up to downloadActiveStartupCap")
    func downloadActivityExtendsAbsoluteWindow() async {
        let scripts = [
            FakeManagedProcess.Script(
                exitAfterLaunch: nil,
                emitOnLaunch: false,
                holdExit: true
            )
        ]
        var policy = ServerSupervisorPolicy.test
        policy.inactivityTimeout = .milliseconds(500)
        policy.absoluteStartupCap = .milliseconds(120)
        policy.downloadActiveStartupCap = .milliseconds(400)
        policy.readinessPollInterval = .milliseconds(20)
        let h = SupervisorHarness(policy: policy, scripts: scripts)
        h.healthOK = false
        h.start()
        await h.waitUntil { h.factory.created.first != nil }

        // Past the ordinary absolute cap, but download progress keeps us alive.
        for i in 0..<6 {
            h.factory.created.first?.emitStderr(
                "downloading: \(i * 10)%| 1MB/s | 5s left\n"
            )
            await h.pump(advance: .milliseconds(40), times: 1)
            #expect(
                failures(h).isEmpty,
                "download-active window should survive past absoluteStartupCap (i=\(i))"
            )
        }

        // Keep emitting until the download-active cap fires.
        for _ in 0..<20 {
            h.factory.created.first?.emitStderr("downloading: 90%| 1MB/s | 1s left\n")
            await h.pump(advance: .milliseconds(40), times: 1)
            if failures(h).contains(where: { $0.kind == .readinessTimedOut }) {
                break
            }
        }

        await h.waitUntil {
            self.failures(h).contains { $0.kind == .readinessTimedOut }
        }
        #expect(failures(h)[0].underlyingMessage?.contains("stalledDownload") == true)
        #expect(failures(h)[0].underlyingMessage?.contains("absoluteCap") != true)
    }

    // MARK: - Port preflight / sentinel

    @Test("port preflight inUse fails before any process creation")
    func portPreflightBlocksSpawn() async {
        let h = SupervisorHarness(policy: .test, scripts: [
            FakeManagedProcess.Script(holdExit: true)
        ])
        h.portResult = .inUse
        h.start()
        await h.waitUntil { !self.failures(h).isEmpty }

        #expect(h.factory.created.isEmpty)
        #expect(failures(h)[0].kind == .portInUse)
    }

    @Test("late child port_in_use sentinel short-circuits retries")
    func latePortSentinel() async {
        let scripts = [
            FakeManagedProcess.Script(
                exitAfterLaunch: nil,
                emitOnLaunch: false,
                holdExit: true
            ),
            FakeManagedProcess.Script(holdExit: true), // must not be used
        ]
        var policy = ServerSupervisorPolicy.test
        policy.inactivityTimeout = .seconds(30)
        policy.absoluteStartupCap = .seconds(30)
        let h = SupervisorHarness(policy: policy, scripts: scripts)
        h.healthOK = false
        h.portResult = .available
        h.start()

        await h.waitUntil { h.factory.created.first?.isRunning == true }
        h.factory.created.first?.emitStderr(
            "LOCAL_DICTATION_FATAL kind=port_in_use detail=bind_failed\n"
        )
        // handleOutput terminates on sentinel; complete the exit if still held.
        await h.pump(advance: .milliseconds(20), times: 5)
        if h.factory.created.first?.isRunning == true {
            h.factory.created.first?.completeExit(.exited(status: 1))
        }

        await h.waitUntil {
            self.failures(h).contains { $0.kind == .portInUse }
        }

        #expect(failures(h)[0].kind == .portInUse)
        #expect(h.factory.created.count == 1, "sentinel must short-circuit retry budget")
        #expect(!h.states.contains(.running))
    }

    // MARK: - Exit / restart budget

    @Test("exit 42 emits restart 1/5…4/5 then failed(consecutiveExits)")
    func exit42Budget() async {
        let scripts = (0..<5).map { i in
            FakeManagedProcess.Script(
                stderrChunks: [Data("boom-\(i)\n".utf8)],
                exitAfterLaunch: .exited(status: 42)
            )
        }
        var policy = ServerSupervisorPolicy.test
        policy.backoffBaseSeconds = 0.001
        policy.backoffCapSeconds = 0.002
        let h = SupervisorHarness(policy: policy, scripts: scripts)
        h.start()

        await h.waitUntil(timeoutAdvances: 500, advance: .milliseconds(5)) {
            self.failures(h).contains { $0.kind == .consecutiveExits }
        }

        let attempts = restartStatuses(h).map(\.attempt)
        #expect(attempts == [1, 2, 3, 4])
        #expect(restartStatuses(h).allSatisfy { $0.maxAttempts == 5 })
        #expect(failures(h).last?.kind == .consecutiveExits)
        #expect(failures(h).last?.stderrTail.contains("boom") == true)
        #expect(h.factory.created.count == 5)
        #expect(!h.states.contains { if case .restarting(let s) = $0 { return s.attempt == 5 }; return false })
    }

    @Test("quick post-health crash consumes budget; stability window resets to attempt 1")
    func stabilityResetsBudget() async {
        // A: healthy then crash inside stability → restart 1
        // B: healthy then crash inside stability → restart 2 (budget consumed)
        // C: healthy past stability then crash → restart 1 (reset)
        let scripts = [
            FakeManagedProcess.Script(exitAfterLaunch: nil, emitOnLaunch: false, holdExit: true),
            FakeManagedProcess.Script(exitAfterLaunch: nil, emitOnLaunch: false, holdExit: true),
            FakeManagedProcess.Script(exitAfterLaunch: nil, emitOnLaunch: false, holdExit: true),
        ]
        var policy = ServerSupervisorPolicy.test
        policy.healthyStabilityWindow = .milliseconds(150)
        policy.backoffBaseSeconds = 0.001
        policy.backoffCapSeconds = 0.002
        policy.inactivityTimeout = .seconds(30)
        policy.absoluteStartupCap = .seconds(30)
        let h = SupervisorHarness(policy: policy, scripts: scripts)
        h.healthOK = false
        h.start()

        // A: become healthy then crash immediately (inside stability window).
        await h.waitUntil { h.factory.created.count >= 1 }
        h.healthOK = true
        await h.waitUntil { h.states.contains(.running) }
        h.factory.created[0].completeExit(.exited(status: 99))
        await h.waitUntil {
            self.restartStatuses(h).contains { $0.attempt == 1 && $0.latestExit.statusCode == 99 }
        }

        // B: healthy then quick crash again → attempt 2.
        h.healthOK = true
        await h.waitUntil { h.states.contains(.running) && h.factory.created.count >= 2 }
        h.factory.created[1].completeExit(.exited(status: 98))
        await h.waitUntil {
            self.restartStatuses(h).contains { $0.attempt == 2 && $0.latestExit.statusCode == 98 }
        }

        // C: stay healthy past stability, then crash → attempt 1 again.
        h.healthOK = true
        await h.waitUntil { h.states.contains(.running) && h.factory.created.count >= 3 }
        await h.pump(advance: .milliseconds(80), times: 4)
        h.factory.created[2].completeExit(.exited(status: 97))
        await h.waitUntil {
            self.restartStatuses(h).contains { $0.attempt == 1 && $0.latestExit.statusCode == 97 }
                || self.failures(h).contains { $0.exit?.statusCode == 97 }
        }

        #expect(restartStatuses(h).contains { $0.attempt == 1 && $0.latestExit.statusCode == 99 })
        #expect(restartStatuses(h).contains { $0.attempt == 2 && $0.latestExit.statusCode == 98 })
        #expect(restartStatuses(h).contains { $0.attempt == 1 && $0.latestExit.statusCode == 97 })
    }

    // MARK: - Stop / generation

    @Test("stop during readiness does not emit failed/restarting or leave child running")
    func stopMidFlightNoBudget() async {
        let scripts = [
            FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true)
        ]
        var policy = ServerSupervisorPolicy.test
        policy.inactivityTimeout = .seconds(30)
        policy.absoluteStartupCap = .seconds(30)
        let h = SupervisorHarness(policy: policy, scripts: scripts)
        h.healthOK = false
        h.start()

        await h.waitUntil { h.factory.created.first?.isRunning == true }
        h.stop()
        await h.pump(advance: .milliseconds(20), times: 8)

        #expect(h.states.contains(.stopped))
        #expect(failures(h).isEmpty)
        #expect(restartStatuses(h).isEmpty)
        #expect(h.factory.created.first?.terminateCount ?? 0 >= 1)
        #expect(h.factory.created.first?.isRunning == false)
        #expect(h.supervisor.state == .stopped)
    }

    @Test("attempt N callbacks cannot mutate state after generation advances")
    func generationIsolation() async {
        let scripts = [
            FakeManagedProcess.Script(exitAfterLaunch: nil, emitOnLaunch: false, holdExit: true)
        ]
        var policy = ServerSupervisorPolicy.test
        policy.inactivityTimeout = .seconds(30)
        policy.absoluteStartupCap = .seconds(30)
        let h = SupervisorHarness(policy: policy, scripts: scripts)
        h.healthOK = false
        h.start()

        await h.waitUntil { h.factory.created.first != nil }
        let process = h.factory.created[0]
        h.stop()
        await h.pump(times: 3)
        let countAfterStop = h.states.count

        process.emitStdout("VOXMLX_READY\n")
        process.emitStderr("downloading: 99%| 1MB/s | 1s left\n")
        process.completeExit(.exited(status: 1))
        h.healthOK = true
        await h.pump(advance: .milliseconds(50), times: 10)

        #expect(h.states.count == countAfterStop)
        #expect(h.states.last == .stopped)
        #expect(failures(h).isEmpty)
    }

    // MARK: - Review regressions

    @Test("stuck pipe EOF does not hang: drain times out and classifies exit")
    func stuckDrainTimesOutAndClassifies() async {
        let scripts = [
            FakeManagedProcess.Script(
                stderrChunks: [Data("boom\n".utf8)],
                exitAfterLaunch: .exited(status: 42),
                emitOnLaunch: true,
                neverEOF: true
            )
        ]
        var policy = ServerSupervisorPolicy.test
        policy.outputDrainTimeout = .milliseconds(40)
        policy.backoffBaseSeconds = 0.001
        policy.backoffCapSeconds = 0.002
        let h = SupervisorHarness(policy: policy, scripts: scripts)
        h.start()

        await h.waitUntil(timeoutAdvances: 80, advance: .milliseconds(20)) {
            !self.restartStatuses(h).isEmpty || !self.failures(h).isEmpty
        }

        #expect(!restartStatuses(h).isEmpty || !failures(h).isEmpty)
        #expect(h.factory.created.first?.forceFinishCount ?? 0 >= 1)

        let exitReason = restartStatuses(h).first?.latestExit.reason
            ?? failures(h).first?.exit?.reason
        guard case .exited(let status) = exitReason else {
            Issue.record("expected concrete exited status, got \(String(describing: exitReason))")
            return
        }
        #expect(status == 42)
    }

    @Test("stop during stuck drain unblocks and leaves no second supervise loop")
    func stopDuringStuckDrainNoDualSupervise() async {
        let scripts = [
            FakeManagedProcess.Script(
                exitAfterLaunch: nil,
                emitOnLaunch: false,
                holdExit: true,
                neverEOF: true
            ),
            FakeManagedProcess.Script(holdExit: true),
        ]
        var policy = ServerSupervisorPolicy.test
        policy.inactivityTimeout = .seconds(30)
        policy.absoluteStartupCap = .seconds(30)
        policy.outputDrainTimeout = .milliseconds(200)
        let h = SupervisorHarness(policy: policy, scripts: scripts)
        h.healthOK = false
        h.start()

        await h.waitUntil { h.factory.created.first?.isRunning == true }
        // Force an exit so supervise enters drainOutput while EOF never arrives.
        h.factory.created[0].completeExit(.exited(status: 9))
        await h.pump(advance: .milliseconds(10), times: 3)

        h.stop()
        await h.pump(advance: .milliseconds(30), times: 8)

        #expect(h.supervisor.state == .stopped)
        #expect(failures(h).isEmpty)
        #expect(restartStatuses(h).isEmpty)

        // start() again must spawn exactly one new child — no dual supervise.
        h.start()
        await h.waitUntil { h.factory.created.count >= 2 }
        await h.pump(advance: .milliseconds(20), times: 5)
        #expect(h.factory.created.count == 2)
        #expect(h.supervisor.state != .stopped || h.states.contains(.launching) || h.states.contains(.waitingForReady))
    }

    @Test("deferred exit publication still reports concrete exit status")
    func deferredExitReportsConcreteStatus() async {
        let scripts = [
            FakeManagedProcess.Script(
                stderrChunks: [Data("crash\n".utf8)],
                exitAfterLaunch: .exited(status: 77),
                emitOnLaunch: true,
                deferExitPublication: true
            )
        ]
        var policy = ServerSupervisorPolicy.test
        policy.backoffBaseSeconds = 0.001
        policy.backoffCapSeconds = 0.002
        let h = SupervisorHarness(policy: policy, scripts: scripts)
        // Fixed path: exit readable from recorded termination as soon as !isRunning.
        h.start()

        await h.waitUntil {
            !self.restartStatuses(h).isEmpty || !self.failures(h).isEmpty
        }

        let reason = restartStatuses(h).first?.latestExit.reason
            ?? failures(h).first?.exit?.reason
        guard case .exited(let status) = reason else {
            Issue.record("expected exited(77), got \(String(describing: reason))")
            return
        }
        #expect(status == 77)
    }

    @Test("deferred-exit fake returns nil under old published-exit race")
    func deferredExitFakeMirrorsOldRace() {
        let process = FakeManagedProcess(script: .init(
            exitAfterLaunch: .exited(status: 55),
            holdExit: true,
            deferExitPublication: true
        ))
        process.useRecordedExitWhenStopped = false
        try? process.launch()
        process.completeExit(.exited(status: 55))
        // Immediately after stop, published exit is still nil (MainActor Task pending).
        #expect(process.isRunning == false)
        #expect(process.exit == nil)

        // Fixed path would already expose the concrete status.
        process.useRecordedExitWhenStopped = true
        #expect(process.exit == .exited(status: 55))
    }

    // MARK: - Same spawn path

    @Test("dev and bundleHelper commands share the same ManagedProcess spawn path")
    func sameSpawnPathForSources() async {
        let commands = [
            ServerLaunchCommand(
                executableURL: URL(fileURLWithPath: "/tmp/dev-serve"),
                argumentPrefix: [],
                source: .development
            ),
            ServerLaunchCommand(
                executableURL: URL(fileURLWithPath: "/tmp/helper"),
                argumentPrefix: ["serve"],
                source: .bundleHelper
            ),
        ]

        for command in commands {
            let h = SupervisorHarness(
                policy: .test,
                scripts: [FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true)],
                command: command
            )
            h.healthOK = true
            h.start()
            await h.waitUntil { h.states.contains(.running) || !self.failures(h).isEmpty }
            #expect(h.factory.created.count == 1, "source \(command.source) should spawn once")
            #expect(h.states.contains(.running))
            h.stop()
            await h.pump(times: 2)
        }
    }
}

@Suite("PortProbe")
struct PortProbeTests {
    @Test("bind on an explicitly held port reports inUse")
    func heldPortIsInUse() throws {
        let listener = try makeListener()
        defer { listener.close() }

        let port = Int(listener.localPort)
        #expect(PortProbe.bind(host: "127.0.0.1", port: port) == .inUse)
    }

    @Test("bind on a free ephemeral-style high port reports available")
    func freePortAvailable() throws {
        // Pick a port, verify available, don't leave it held.
        let probe = try makeListener()
        let port = Int(probe.localPort)
        probe.close()
        // Brief moment for kernel to release; bind probe should succeed.
        #expect(PortProbe.bind(host: "127.0.0.1", port: port) == .available)
    }

    private func makeListener() throws -> HeldPort {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PortTestError.socket }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw PortTestError.bind
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw PortTestError.listen
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else {
            close(fd)
            throw PortTestError.getsockname
        }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        return HeldPort(fd: fd, localPort: UInt16(port))
    }
}

private enum PortTestError: Error {
    case socket, bind, listen, getsockname
}

private final class HeldPort {
    let fd: Int32
    let localPort: UInt16
    init(fd: Int32, localPort: UInt16) {
        self.fd = fd
        self.localPort = localPort
    }
    func close() { Darwin.close(fd) }
    deinit { Darwin.close(fd) }
}
