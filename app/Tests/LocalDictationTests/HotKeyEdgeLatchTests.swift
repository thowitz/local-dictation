import Foundation
import Testing
@testable import LocalDictation

@Suite("HotKeyEdgeLatch")
struct HotKeyEdgeLatchTests {
    @Test("First pressed delivers; repeated pressed while down is suppressed")
    func firstPressedDeliversRepeatedSuppressed() {
        var latch = HotKeyEdgeLatch(requiresReleaseToRearm: true)
        #expect(latch.pressed() == true)
        #expect(latch.pressed() == false)
        #expect(latch.pressed() == false)
    }

    @Test("Only matching released delivers; unmatched released is false")
    func matchingReleasedDeliversUnmatchedIgnored() {
        var latch = HotKeyEdgeLatch(requiresReleaseToRearm: true)
        #expect(latch.released() == false)
        #expect(latch.pressed() == true)
        #expect(latch.released() == true)
        #expect(latch.released() == false)
    }

    @Test("Reset re-arms a fresh press cycle")
    func resetRearmsFreshCycle() {
        var latch = HotKeyEdgeLatch(requiresReleaseToRearm: true)
        #expect(latch.pressed() == true)
        latch.reset()
        #expect(latch.released() == false)
        #expect(latch.pressed() == true)
        #expect(latch.released() == true)
    }

    @Test("Release-required latch sticks if release is dropped until reset")
    func releaseRequiredSticksUntilReset() {
        var latch = HotKeyEdgeLatch(requiresReleaseToRearm: true)
        #expect(latch.pressed() == true)
        // Missed release — further presses stay suppressed.
        #expect(latch.pressed() == false)
        latch.reset()
        #expect(latch.pressed() == true)
    }

    @Test("Toggle-style latch re-arms on press after a dropped release")
    func toggleStyleRearmsWithoutRelease() {
        var latch = HotKeyEdgeLatch(requiresReleaseToRearm: false)
        #expect(latch.pressed() == true)
        // Missed release must not brick the recovery/dev toggle.
        #expect(latch.pressed() == true)
        #expect(latch.released() == true)
        #expect(latch.pressed() == true)
    }
}
