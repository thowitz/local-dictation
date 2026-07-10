import Foundation
import Testing
@testable import LocalDictation

@Suite("CancellationBarrier")
struct CancellationBarrierTests {
    @Test("Normal delta/done accepted in listening and flushing")
    func normalTranscriptAcceptedInActivePhases() {
        var barrier = CancellationBarrier()
        #expect(barrier.shouldAcceptTranscript(phase: .listening))
        #expect(barrier.shouldAcceptTranscript(phase: .flushing))
        #expect(!barrier.shouldAcceptTranscript(phase: .inactive))
    }

    @Test("Delta/done rejected while awaiting clear in listening and flushing")
    func transcriptRejectedWhileAwaitingClear() {
        var barrier = CancellationBarrier()
        barrier.beginCancel()
        #expect(barrier.isAwaitingClear)
        #expect(!barrier.shouldAcceptTranscript(phase: .listening))
        #expect(!barrier.shouldAcceptTranscript(phase: .flushing))
        #expect(!barrier.shouldAcceptTranscript(phase: .inactive))
    }

    @Test("Transcript accepted again only after bufferCleared")
    func transcriptAcceptedAgainOnlyAfterBufferCleared() {
        var barrier = CancellationBarrier()
        barrier.beginCancel()
        #expect(!barrier.shouldAcceptTranscript(phase: .listening))

        #expect(barrier.bufferCleared() == true)
        #expect(!barrier.isAwaitingClear)
        #expect(barrier.shouldAcceptTranscript(phase: .listening))
        #expect(barrier.shouldAcceptTranscript(phase: .flushing))

        // Spurious second ack is a no-op.
        #expect(barrier.bufferCleared() == false)
        #expect(barrier.shouldAcceptTranscript(phase: .listening))
    }

    @Test("Pending hold released during barrier does not start when ack arrives")
    func pendingHoldReleasedDuringBarrierDoesNotStartOnAck() {
        var barrier = CancellationBarrier()
        var intent = DictationIntentTracker()

        barrier.beginCancel()
        #expect(!barrier.shouldAllowStart(hasPendingIntent: true))

        // Hold pressed while barrier is closed, then released before the clear ack.
        intent.queue(.micHold)
        #expect(intent.handleHoldRelease() == .canceledPending)
        #expect(!intent.shouldBeginOnReadiness)

        #expect(barrier.bufferCleared() == true)
        #expect(
            !barrier.shouldAllowStart(hasPendingIntent: intent.shouldBeginOnReadiness)
        )
    }

    @Test("Pending hold still held through barrier may start after ack")
    func pendingHoldStillHeldMayStartAfterAck() {
        var barrier = CancellationBarrier()
        var intent = DictationIntentTracker()

        barrier.beginCancel()
        intent.queue(.micHold)
        #expect(!barrier.shouldAllowStart(hasPendingIntent: intent.shouldBeginOnReadiness))

        #expect(barrier.bufferCleared() == true)
        #expect(barrier.shouldAllowStart(hasPendingIntent: intent.shouldBeginOnReadiness))
    }

    @Test("Clear enqueue failure opens the barrier immediately")
    func clearEnqueueFailureOpensBarrier() {
        var barrier = CancellationBarrier()
        barrier.beginCancel()
        barrier.clearEnqueueFailed()
        #expect(!barrier.isAwaitingClear)
        #expect(barrier.shouldAcceptTranscript(phase: .listening))
        #expect(barrier.shouldAllowStart(hasPendingIntent: true))
    }
}
