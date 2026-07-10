import Foundation
import Testing
@testable import LocalDictation

@Suite("RemapHealthMonitor")
@MainActor
struct RemapHealthMonitorTests {
    private final class State {
        var expectedActive = true
        var persistenceDesired = true
        var remap: MicKeyRemapStatus = .missing
        var agent: LaunchAgentStatus = .absent
        var mutationInProgress = false
        var setupVisibleIncomplete = false
        var issues: [RemapHealthIssue] = []
        var remapProbeCount = 0
    }

    private func pump(_ clock: FakeClock, advance: Duration, times: Int = 1) async {
        for _ in 0..<times {
            await Task.yield()
            clock.advance(by: advance)
            await Task.yield()
        }
    }

    private func makeMonitor(
        state: State,
        clock: FakeClock,
        policy: RemapHealthMonitor.Policy = RemapHealthMonitor.Policy(
            launchInitialDelay: .milliseconds(20),
            launchRetryDelay: .milliseconds(10),
            launchMissingRetries: 2,
            wakeInitialDelay: .milliseconds(10),
            wakeMissingRetries: 1,
            notNowCooldown: .milliseconds(50)
        )
    ) -> RemapHealthMonitor {
        let monitor = RemapHealthMonitor(
            policy: policy,
            dependencies: RemapHealthMonitor.Dependencies(
                sleep: { try await clock.sleep($0) },
                now: { clock.now },
                expectedActive: { state.expectedActive },
                persistenceDesired: { state.persistenceDesired },
                remapStatus: {
                    state.remapProbeCount += 1
                    return state.remap
                },
                launchAgentStatus: { state.agent },
                isMutationInProgress: { state.mutationInProgress },
                isSetupVisibleAndIncomplete: { state.setupVisibleIncomplete }
            )
        )
        monitor.onIssue = { state.issues.append($0) }
        return monitor
    }

    @Test("Launch waits, retries missing map, then prompts")
    func launchRetriesThenPrompts() async {
        let clock = FakeClock()
        let state = State()
        let monitor = makeMonitor(state: state, clock: clock)
        monitor.scheduleLaunchCheck()

        await pump(clock, advance: .milliseconds(15))
        #expect(state.issues.isEmpty)

        await pump(clock, advance: .milliseconds(10), times: 6)
        #expect(state.issues.count == 1)
        #expect(state.issues[0].outcome == .expectedMappingMissing)
        #expect(state.issues[0].trigger == .launch)
        #expect(state.remapProbeCount >= 3)
    }

    @Test("Wake uses shorter delay and one retry")
    func wakeRetry() async {
        let clock = FakeClock()
        let state = State()
        let monitor = makeMonitor(state: state, clock: clock)
        monitor.scheduleWakeOrSessionCheck()

        await pump(clock, advance: .milliseconds(8))
        #expect(state.issues.isEmpty)
        await pump(clock, advance: .milliseconds(10), times: 4)
        #expect(state.issues.count == 1)
        #expect(state.issues[0].trigger == .wakeOrSessionActive)
    }

    @Test("Superseded check is cancelled by a newer schedule")
    func debounceCancellation() async {
        let clock = FakeClock()
        let state = State()
        let monitor = makeMonitor(state: state, clock: clock)
        monitor.scheduleLaunchCheck()
        await pump(clock, advance: .milliseconds(5))
        state.remap = .installed
        state.agent = .loaded
        monitor.scheduleWakeOrSessionCheck()
        await pump(clock, advance: .milliseconds(20), times: 4)
        #expect(state.issues.isEmpty)
    }

    @Test("Mutation in progress gates the check")
    func mutationGate() async {
        let clock = FakeClock()
        let state = State()
        state.mutationInProgress = true
        let monitor = makeMonitor(state: state, clock: clock)
        monitor.scheduleLaunchCheck()
        await pump(clock, advance: .milliseconds(40), times: 4)
        #expect(state.issues.isEmpty)
    }

    @Test("Setup visible and incomplete suppresses prompt")
    func setupVisibleSuppression() async {
        let clock = FakeClock()
        let state = State()
        state.setupVisibleIncomplete = true
        let monitor = makeMonitor(state: state, clock: clock)
        monitor.scheduleLaunchCheck()
        await pump(clock, advance: .milliseconds(40), times: 6)
        #expect(state.issues.isEmpty)
    }

    @Test("Not Now preserves expectation and cools down prompts")
    func notNowCooldown() async {
        let clock = FakeClock()
        let state = State()
        let monitor = makeMonitor(state: state, clock: clock)
        monitor.scheduleLaunchCheck()
        await pump(clock, advance: .milliseconds(40), times: 6)
        #expect(state.issues.count == 1)
        monitor.noteNotNow()
        #expect(state.expectedActive)

        state.issues.removeAll()
        monitor.scheduleWakeOrSessionCheck()
        await pump(clock, advance: .milliseconds(20), times: 4)
        #expect(state.issues.isEmpty)

        await pump(clock, advance: .milliseconds(40), times: 2)
        monitor.scheduleWakeOrSessionCheck()
        await pump(clock, advance: .milliseconds(20), times: 4)
        #expect(state.issues.count == 1)
    }

    @Test("Probe failure never prompts as missing")
    func probeFailureNoPrompt() async {
        let clock = FakeClock()
        let state = State()
        state.remap = .probeFailed("boom")
        let monitor = makeMonitor(state: state, clock: clock)
        monitor.scheduleLaunchCheck()
        await pump(clock, advance: .milliseconds(40), times: 4)
        #expect(state.issues.isEmpty)
    }

    @Test("Persistence repair issue is presented when mapping active")
    func persistenceRepairPrompt() async {
        let clock = FakeClock()
        let state = State()
        state.remap = .installed
        state.agent = .validButUnloaded
        let monitor = makeMonitor(state: state, clock: clock)
        monitor.scheduleLaunchCheck()
        await pump(clock, advance: .milliseconds(30), times: 3)
        #expect(state.issues.count == 1)
        #expect(state.issues[0].outcome == .activeButPersistenceNeedsRepair)
        #expect(state.issues[0].prefersRepairCopy)
    }

    @Test("Expectation cleared mid-check prevents prompt")
    func expectationClearedMidCheck() async {
        let clock = FakeClock()
        let state = State()
        let monitor = makeMonitor(state: state, clock: clock)
        monitor.scheduleLaunchCheck()
        await pump(clock, advance: .milliseconds(15))
        state.expectedActive = false
        await pump(clock, advance: .milliseconds(40), times: 4)
        #expect(state.issues.isEmpty)
    }

    @Test("One prompt gate suppresses duplicate issues until dismissed")
    func onePromptGate() async {
        let clock = FakeClock()
        let state = State()
        let monitor = makeMonitor(state: state, clock: clock)
        monitor.scheduleLaunchCheck()
        await pump(clock, advance: .milliseconds(40), times: 6)
        #expect(state.issues.count == 1)

        monitor.scheduleWakeOrSessionCheck()
        await pump(clock, advance: .milliseconds(30), times: 4)
        #expect(state.issues.count == 1)

        monitor.notePromptDismissed()
        monitor.scheduleWakeOrSessionCheck()
        await pump(clock, advance: .milliseconds(30), times: 4)
        #expect(state.issues.count == 2)
    }

    @Test("Historical completion with visible incomplete setup still suppresses")
    func historicalCompletionVisibleIncompleteSuppresses() async {
        let clock = FakeClock()
        let state = State()
        // Live checklist incomplete even if historical version was completed.
        state.setupVisibleIncomplete = true
        let monitor = makeMonitor(state: state, clock: clock)
        monitor.scheduleLaunchCheck()
        await pump(clock, advance: .milliseconds(40), times: 6)
        #expect(state.issues.isEmpty)
    }

    @Test("Healthy mapping produces no issue")
    func healthyNoIssue() async {
        let clock = FakeClock()
        let state = State()
        state.remap = .installed
        state.agent = .loaded
        let monitor = makeMonitor(state: state, clock: clock)
        monitor.scheduleLaunchCheck()
        await pump(clock, advance: .milliseconds(40), times: 3)
        #expect(state.issues.isEmpty)
    }
}
