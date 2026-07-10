import Darwin
import Foundation
import Testing
@testable import LocalDictation

final class FakeRealtimeClient: DictationRealtimeClient {
    private(set) var connectionState: RealtimeClient.ConnectionState = .disconnected
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var eventLog: [String] = []
    private var callbacks = RealtimeClient.Callbacks()
    var commitSucceeds = true
    var clearSucceeds = true

    var isConnected: Bool { connectionState == .connected }

    func setCallbacks(_ callbacks: RealtimeClient.Callbacks) {
        self.callbacks = callbacks
    }

    func connect() {
        connectCount += 1
        eventLog.append("connect")
        connectionState = .connecting
        callbacks.onConnectionState?(.connecting)
        connectionState = .connected
        callbacks.onConnectionState?(.connected)
    }

    func disconnect() {
        disconnectCount += 1
        eventLog.append("disconnect")
        connectionState = .disconnected
        callbacks.onConnectionState?(.disconnected)
    }

    func sendAudio(_ pcm16: Data) {
        eventLog.append("audio:\(pcm16.count)")
    }

    @discardableResult
    func commitFinal() -> Bool {
        eventLog.append("commit")
        return commitSucceeds
    }

    @discardableResult
    func clearBuffer() -> Bool {
        eventLog.append("clear")
        return clearSucceeds
    }

    func emitDone(_ transcript: String = "") {
        callbacks.onDone?(transcript)
    }

    /// Idle transport loss (not an intentional `disconnect()`).
    func simulateTransportDrop() {
        eventLog.append("drop")
        connectionState = .disconnected
        callbacks.onConnectionState?(.disconnected)
    }
}

@Suite("DictationControllerLifecycle")
@MainActor
struct DictationControllerLifecycleTests {
    private func makeController(
        idleMinutes: Double,
        scripts: [FakeManagedProcess.Script],
        terminationGrace: Duration = .milliseconds(5)
    ) -> (DictationController, FakeRealtimeClient, SupervisorHarness) {
        let config = AppConfig(port: 8471, idleUnloadMinutes: idleMinutes)
        var policy = ServerSupervisorPolicy.test
        policy.inactivityTimeout = .seconds(30)
        policy.absoluteStartupCap = .seconds(30)
        policy.terminationGrace = terminationGrace
        let harness = SupervisorHarness(config: config, policy: policy, scripts: scripts)
        let realtime = FakeRealtimeClient()
        let deps = DictationController.Dependencies(
            sleep: { try await harness.clock.sleep($0) },
            isSecureEventInputEnabled: { false },
            isAccessibilityTrusted: { true },
            startAudio: { _ in },
            stopAudio: {},
            presentsSessionUI: false
        )
        let controller = DictationController(
            config: config,
            dependencies: deps,
            supervisor: harness.supervisor,
            realtime: realtime
        )
        return (controller, realtime, harness)
    }

    /// Wait without advancing the fake clock (idle deadlines must stay intact).
    private func waitSettled(
        _ harness: SupervisorHarness,
        timeoutYields: Int = 400,
        _ predicate: () -> Bool
    ) async {
        for _ in 0..<timeoutYields {
            if predicate() { return }
            await Task.yield()
            await harness.pump(advance: .zero, times: 1)
        }
    }

    private func bootstrapReady(
        _ controller: DictationController,
        _ harness: SupervisorHarness
    ) async {
        harness.healthOK = true
        controller.bootstrap()
        await waitSettled(harness) { harness.states.contains(.running) }
        await waitSettled(harness) { controller.state == .ready }
        #expect(controller.state == .ready)
    }

    @Test("Ready plus socket arms idle; timeout disconnects before stop")
    func readyArmsIdleAndTimeoutDisconnectsBeforeStop() async {
        let scripts = [FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true)]
        let (controller, realtime, harness) = makeController(idleMinutes: 0.05, scripts: scripts)
        await bootstrapReady(controller, harness)
        #expect(controller.isIdleSchedulerArmed)

        await harness.pump(advance: .seconds(1), times: 2)
        #expect(controller.state == .ready)

        await harness.pump(advance: .seconds(2.5), times: 3)
        await waitSettled(harness) { controller.state == .idle }
        #expect(controller.state == .idle)
        #expect(realtime.disconnectCount >= 1)
        #expect(harness.states.contains(.stopped))
        #expect(realtime.eventLog.contains("disconnect"))
        #expect(!controller.isIdleSchedulerArmed)
    }

    @Test("Idle socket drop does not reset idle deadline; unload still fires")
    func idleSocketDropDoesNotResetIdleDeadline() async {
        let scripts = [FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true)]
        let (controller, realtime, harness) = makeController(idleMinutes: 0.05, scripts: scripts)
        await bootstrapReady(controller, harness)
        #expect(controller.isIdleSchedulerArmed)

        // Burn part of the original interval, then drop the socket while idle.
        await harness.pump(advance: .seconds(1), times: 1)
        #expect(controller.state == .ready)
        realtime.simulateTransportDrop()
        await waitSettled(harness) { controller.state == .starting }
        #expect(controller.state == .starting)
        #expect(controller.isIdleSchedulerArmed)
        #expect(harness.supervisor.desiredRunning)

        // Advance past the ORIGINAL 3s deadline (1s already elapsed → 2.5s more).
        await harness.pump(advance: .seconds(2.5), times: 3)
        await waitSettled(harness) { controller.state == .idle }
        #expect(controller.state == .idle)
        #expect(harness.states.contains(.stopped))
        #expect(!harness.supervisor.desiredRunning)
        #expect(realtime.eventLog.contains("disconnect"))
        #expect(harness.factory.created.first?.isRunning == false)
    }

    @Test("Pending intent cancels idle arming")
    func pendingIntentCancelsIdleArming() async {
        let scripts = [FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true)]
        let (controller, _, harness) = makeController(idleMinutes: 0.05, scripts: scripts)
        await bootstrapReady(controller, harness)
        #expect(controller.isIdleSchedulerArmed)

        controller.beginHoldDictation()
        #expect(!controller.isIdleSchedulerArmed)
        #expect(controller.state == .listening)

        await harness.pump(advance: .seconds(5), times: 3)
        #expect(controller.state == .listening)
        #expect(harness.factory.created.first?.isRunning == true)
    }

    @Test("Listening and flushing are excluded from unload")
    func listeningAndFlushingExcludedFromUnload() async {
        let scripts = [FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true)]
        let (controller, realtime, harness) = makeController(idleMinutes: 0.05, scripts: scripts)
        await bootstrapReady(controller, harness)

        controller.startDictation()
        #expect(controller.state == .listening)
        #expect(!controller.isIdleSchedulerArmed)

        controller.stopDictation()
        #expect(controller.state == .flushing)
        #expect(!controller.isIdleSchedulerArmed)

        await harness.pump(advance: .seconds(5), times: 3)
        #expect(controller.state == .flushing)
        #expect(harness.factory.created.first?.isRunning == true)

        realtime.emitDone("hello")
        await waitSettled(harness) { controller.state == .ready }
        #expect(controller.state == .ready)
        #expect(controller.isIdleSchedulerArmed)
    }

    @Test("Session end resets a full idle interval")
    func sessionEndResetsFullIdleInterval() async {
        // Use a long idle window so supervisor readiness sleeps are unaffected.
        let scripts = [FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true)]
        let (controller, realtime, harness) = makeController(idleMinutes: 1, scripts: scripts)
        await bootstrapReady(controller, harness)

        await harness.pump(advance: .seconds(45), times: 1)
        #expect(controller.state == .ready)
        #expect(controller.isIdleSchedulerArmed)

        controller.startDictation()
        #expect(controller.state == .listening)
        controller.stopDictation()
        #expect(controller.state == .flushing)
        realtime.emitDone("x")
        await waitSettled(harness) { controller.state == .ready }
        #expect(controller.state == .ready)
        #expect(controller.isIdleSchedulerArmed)

        // Prior 45s must not count; need a full fresh minute.
        await harness.pump(advance: .seconds(45), times: 1)
        #expect(controller.state == .ready)
        await harness.pump(advance: .seconds(20), times: 1)
        await waitSettled(harness) { controller.state == .idle }
        #expect(controller.state == .idle)
    }

    @Test("Brief hold withdrawal before readiness does not begin listening")
    func briefHoldWithdrawalBeforeReadiness() async {
        let scripts = [
            FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true),
            FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true),
        ]
        let (controller, _, harness) = makeController(idleMinutes: 0.05, scripts: scripts)
        await bootstrapReady(controller, harness)
        await harness.pump(advance: .seconds(4), times: 3)
        await waitSettled(harness) { controller.state == .idle }

        harness.healthOK = false
        controller.beginHoldDictation()
        #expect(controller.state == .starting)
        controller.endHoldDictation()

        harness.healthOK = true
        await waitSettled(harness) { harness.states.contains(.running) && controller.state == .ready }
        #expect(controller.state == .ready)
        #expect(controller.isIdleSchedulerArmed)
    }

    @Test("Warm relaunch from dormant shows warming then listens when intent remains")
    func warmRelaunchFromDormant() async {
        let scripts = [
            FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true),
            FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true),
        ]
        let (controller, _, harness) = makeController(idleMinutes: 0.05, scripts: scripts)
        await bootstrapReady(controller, harness)
        await harness.pump(advance: .seconds(4), times: 3)
        await waitSettled(harness) { controller.state == .idle }
        #expect(harness.factory.created.count == 1)

        controller.startDictation()
        #expect(controller.state == .starting)
        #expect(controller.state.statusTitle == "Warming up…")

        await waitSettled(harness) { harness.factory.created.count == 2 && controller.state == .listening }
        #expect(controller.state == .listening)
        #expect(harness.factory.created.count == 2)
    }

    @Test("Request during unloading shows warming and queues one relaunch")
    func requestDuringUnloadingWarmsAndRelaunches() async {
        let scripts = [
            FakeManagedProcess.Script(
                exitAfterLaunch: nil,
                holdExit: true,
                holdTerminateExit: true
            ),
            FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true),
        ]
        let (controller, _, harness) = makeController(
            idleMinutes: 0.05,
            scripts: scripts,
            terminationGrace: .milliseconds(10)
        )
        await bootstrapReady(controller, harness)
        await harness.pump(advance: .seconds(4), times: 3)
        await waitSettled(harness) { controller.state == .unloading }
        #expect(controller.state == .unloading)

        controller.startDictation()
        #expect(controller.state == .starting)
        #expect(harness.factory.created.count == 1)

        harness.factory.created[0].completeExit(.signaled(signal: SIGTERM))
        // Readiness polling uses the fake clock — advance while waiting for warm relaunch.
        for _ in 0..<40 {
            if controller.state == .listening { break }
            await harness.pump(advance: .milliseconds(20), times: 1)
        }
        #expect(controller.state == .listening)
        #expect(harness.factory.created.count == 2)
    }

    @Test("Shutdown is idempotent and stops with applicationQuit")
    func shutdownIsIdempotent() async {
        let scripts = [FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true)]
        let (controller, realtime, harness) = makeController(idleMinutes: 0.05, scripts: scripts)
        await bootstrapReady(controller, harness)
        #expect(controller.isIdleSchedulerArmed)

        controller.shutdown()
        controller.shutdown()
        await waitSettled(harness) { harness.states.contains(.stopped) }
        #expect(!controller.isIdleSchedulerArmed)
        #expect(realtime.disconnectCount >= 1)
        #expect(!harness.supervisor.desiredRunning)
        #expect(harness.factory.created.first?.isRunning == false)
    }

    @Test("Zero idle config never arms scheduler")
    func zeroIdleNeverArms() async {
        let scripts = [FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true)]
        let (controller, _, harness) = makeController(idleMinutes: 0, scripts: scripts)
        await bootstrapReady(controller, harness)
        #expect(!controller.isIdleSchedulerArmed)
        await harness.pump(advance: .seconds(60), times: 2)
        #expect(controller.state == .ready)
        #expect(harness.factory.created.first?.isRunning == true)
    }
}
