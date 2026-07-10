import Foundation
import Testing
@testable import LocalDictation

@Suite("DictationIntentTracker")
struct DictationIntentTrackerTests {
    @Test("Pending hold canceled by release before readiness")
    func pendingHoldCanceledByReleaseBeforeReady() {
        var tracker = DictationIntentTracker()
        tracker.queue(.micHold)
        #expect(tracker.pending == .micHold)
        #expect(tracker.handleHoldRelease() == .canceledPending)
        #expect(tracker.pending == nil)
        #expect(tracker.active == nil)
    }

    @Test("Readiness no-ops after pending hold cancellation")
    func readinessNoOpsAfterCancellation() {
        var tracker = DictationIntentTracker()
        tracker.queue(.micHold)
        _ = tracker.handleHoldRelease()
        #expect(!tracker.shouldBeginOnReadiness)
        tracker.activatePending()
        #expect(tracker.active == nil)
        #expect(tracker.pending == nil)
    }

    @Test("Pending hold activates when still held at readiness")
    func pendingHoldActivatesWhenStillHeld() {
        var tracker = DictationIntentTracker()
        tracker.queue(.micHold)
        #expect(tracker.shouldBeginOnReadiness)
        tracker.activatePending()
        #expect(tracker.pending == nil)
        #expect(tracker.active == .micHold)
    }

    @Test("Active hold release requests exactly one stop")
    func activeHoldReleaseRequestsExactlyOneStop() {
        var tracker = DictationIntentTracker()
        tracker.queue(.micHold)
        tracker.activatePending()
        #expect(tracker.handleHoldRelease() == .requestStop)
        #expect(tracker.active == nil)
        // Second release must not request another stop.
        #expect(tracker.handleHoldRelease() == .ignored)
    }

    @Test("Release during reconnect removes requeued hold")
    func releaseDuringReconnectRemovesRequeuedHold() {
        var tracker = DictationIntentTracker()
        tracker.queue(.micHold)
        tracker.activatePending()
        // Transport loss: active hold is requeued as pending so reconnect cannot
        // auto-start, but a later physical release can still clear it.
        tracker.interruptActiveSession()
        #expect(tracker.active == nil)
        #expect(tracker.pending == .micHold)
        #expect(tracker.handleHoldRelease() == .canceledPending)
        #expect(tracker.pending == nil)
        #expect(!tracker.shouldBeginOnReadiness)
    }

    @Test("Manual intent is not ended by unrelated hold release")
    func manualIntentNotEndedByUnrelatedHoldRelease() {
        var tracker = DictationIntentTracker()
        tracker.queue(.manualToggle)
        #expect(tracker.handleHoldRelease() == .ignored)
        #expect(tracker.pending == .manualToggle)

        tracker.activatePending()
        #expect(tracker.active == .manualToggle)
        #expect(tracker.handleHoldRelease() == .ignored)
        #expect(tracker.active == .manualToggle)
    }

    @Test("Esc or failure clears all intent")
    func escOrFailureClearsAllIntent() {
        var tracker = DictationIntentTracker()
        tracker.queue(.micHold)
        tracker.activatePending()
        tracker.queue(.manualToggle) // pending alongside active shouldn't happen, but clearAll wipes both
        tracker.clearAll()
        #expect(tracker.pending == nil)
        #expect(tracker.active == nil)
        #expect(!tracker.shouldBeginOnReadiness)
        #expect(tracker.handleHoldRelease() == .ignored)
    }
}
