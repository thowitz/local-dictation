import Foundation
import Testing
@testable import LocalDictation

/// End-to-end controller behaviour for transcript events: ordering, audio
/// gating around commit, and bounded on-screen edits.
@Suite("DictationTranscript")
@MainActor
struct DictationTranscriptTests {
    /// Captures typed edits and the audio handler the controller installs.
    final class Probe: @unchecked Sendable {
        var screen = ScreenModel("PROMPT: ")
        var edits: [TypingEdit] = []
        var audioHandler: (@Sendable (Data) -> Void)?
    }

    private func makeController() -> (DictationController, FakeRealtimeClient, SupervisorHarness, Probe) {
        let config = AppConfig(port: 8471, idleUnloadMinutes: 0)
        var policy = ServerSupervisorPolicy.test
        policy.inactivityTimeout = .seconds(30)
        policy.absoluteStartupCap = .seconds(30)
        policy.terminationGrace = .milliseconds(5)
        let harness = SupervisorHarness(
            config: config,
            policy: policy,
            scripts: [FakeManagedProcess.Script(exitAfterLaunch: nil, holdExit: true)]
        )
        let realtime = FakeRealtimeClient()
        let probe = Probe()
        let deps = DictationController.Dependencies(
            sleep: { try await harness.clock.sleep($0) },
            isSecureEventInputEnabled: { false },
            isAccessibilityTrusted: { true },
            startAudio: { handler in probe.audioHandler = handler },
            stopAudio: {
                // Real capture flushes its tail synchronously on stop.
                probe.audioHandler?(Data(repeating: 9, count: 640))
            },
            presentsSessionUI: false,
            typeEdit: { edit in
                probe.edits.append(edit)
                probe.screen.apply(edit)
            }
        )
        let controller = DictationController(
            config: config,
            dependencies: deps,
            supervisor: harness.supervisor,
            realtime: realtime
        )
        return (controller, realtime, harness, probe)
    }

    private func settle(_ harness: SupervisorHarness, _ predicate: () -> Bool = { false }) async {
        for _ in 0..<400 {
            if predicate() { return }
            await Task.yield()
            await harness.pump(advance: .zero, times: 1)
        }
    }

    private func listening() async -> (DictationController, FakeRealtimeClient, SupervisorHarness, Probe) {
        let (controller, realtime, harness, probe) = makeController()
        harness.healthOK = true
        controller.bootstrap()
        await settle(harness) { controller.state == .ready }
        controller.startDictation()
        #expect(controller.state == .listening)
        return (controller, realtime, harness, probe)
    }

    @Test("Snapshots type committed text once and correct only the draft")
    func snapshotsTypeBoundedEdits() async {
        let (controller, realtime, harness, probe) = await listening()
        realtime.emitTranscript(.snapshot(.init(committed: "", draft: "hello wor")))
        realtime.emitTranscript(.snapshot(.init(committed: "hello", draft: "world how")))
        realtime.emitTranscript(.snapshot(.init(committed: "hello world", draft: "who are")))
        controller.stopDictation()
        realtime.emitDone("hello world, how are you?")
        await settle(harness) { controller.state == .ready }

        #expect(probe.screen.text == "PROMPT: hello world, how are you?")
        #expect(probe.edits.allSatisfy { $0.deleteCount <= "who are".count + 1 })
    }

    @Test("Events are applied in delivery order")
    func eventsApplyInOrder() async {
        let (controller, realtime, harness, probe) = await listening()
        // A burst delivered from another thread, then done.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                for n in 1...50 {
                    let words = (0..<n).map { "w\($0)" }
                    realtime.emitTranscript(
                        .snapshot(.init(committed: words.dropLast().joined(separator: " "), draft: words.last!))
                    )
                }
                continuation.resume()
            }
        }
        controller.stopDictation()
        realtime.emitDone((0..<50).map { "w\($0)" }.joined(separator: " "))
        await settle(harness) { controller.state == .ready }
        #expect(probe.screen.text == "PROMPT: " + (0..<50).map { "w\($0)" }.joined(separator: " "))
        #expect(probe.edits.allSatisfy { $0.deleteCount == 0 })
    }

    @Test("Audio tail reaches the client before commit; nothing after")
    func audioGatedAroundCommit() async {
        let (controller, realtime, harness, probe) = await listening()
        let handler = probe.audioHandler
        handler?(Data(repeating: 1, count: 3200))
        controller.stopDictation()
        #expect(realtime.eventLog.suffix(3) == ["audio:3200", "audio:640", "commit"])
        // A late capture callback after release must not reach the client.
        handler?(Data(repeating: 2, count: 1600))
        realtime.emitDone("")
        await settle(harness) { controller.state == .ready }
        #expect(!realtime.eventLog.contains("audio:1600"))
        #expect(realtime.eventLog.last == "commit")
    }

    @Test("Voxtral deltas append; end-of-speech mid-session starts a new segment")
    func voxtralDeltasAndSegments() async {
        let (controller, realtime, harness, probe) = await listening()
        realtime.emitTranscript(.append("Hello"))
        realtime.emitTranscript(.append(" there."))
        realtime.emitDone("Hello there.")
        realtime.emitTranscript(.append(" Again"))
        await settle(harness) { probe.screen.text.hasSuffix("Again") }
        controller.stopDictation()
        realtime.emitDone(" Again")
        await settle(harness) { controller.state == .ready }
        #expect(probe.screen.text == "PROMPT: Hello there. Again")
    }

    @Test("Esc cancel keeps typed text and ignores late transcript events")
    func cancelIgnoresLateEvents() async {
        let (controller, realtime, harness, probe) = await listening()
        realtime.emitTranscript(.snapshot(.init(committed: "keep this", draft: "maybe")))
        await settle(harness) { probe.screen.text.hasSuffix("maybe") }
        controller.cancelDictation()
        realtime.emitTranscript(.snapshot(.init(committed: "keep this and more", draft: "")))
        realtime.emitDone("keep this and more")
        await settle(harness)
        #expect(probe.screen.text == "PROMPT: keep this maybe")
    }
}
