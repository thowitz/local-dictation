import Foundation
import Testing
@testable import LocalDictation

@Suite("MicKeyGestureInterpreter")
struct MicKeyGestureInterpreterTests {
    @Test("Hold mode emits beginHold on down and endHold on up")
    func holdDownUp() {
        var interpreter = MicKeyGestureInterpreter()
        #expect(interpreter.keyDown(mode: .holdToTalk) == .beginHold)
        #expect(interpreter.keyUp() == .endHold)
    }

    @Test("Toggle mode emits toggle on down and nil on up")
    func toggleDownUp() {
        var interpreter = MicKeyGestureInterpreter()
        #expect(interpreter.keyDown(mode: .toggle) == .toggle)
        #expect(interpreter.keyUp() == nil)
    }

    @Test("Mode is latched across a mid-press preference change")
    func modeLatchedAcrossMidPressPrefChange() {
        var interpreter = MicKeyGestureInterpreter()
        #expect(interpreter.keyDown(mode: .holdToTalk) == .beginHold)
        // Preference flips to toggle while key is still held — up still ends the hold.
        #expect(interpreter.keyUp() == .endHold)

        // Next gesture uses the new mode.
        #expect(interpreter.keyDown(mode: .toggle) == .toggle)
        #expect(interpreter.keyUp() == nil)
    }

    @Test("Unmatched release is ignored")
    func unmatchedReleaseIgnored() {
        var interpreter = MicKeyGestureInterpreter()
        #expect(interpreter.keyUp() == nil)
    }

    @Test("Repeated down while held is ignored")
    func repeatedDownIgnored() {
        var interpreter = MicKeyGestureInterpreter()
        #expect(interpreter.keyDown(mode: .holdToTalk) == .beginHold)
        #expect(interpreter.keyDown(mode: .holdToTalk) == nil)
        #expect(interpreter.keyDown(mode: .toggle) == nil)
        #expect(interpreter.keyUp() == .endHold)
    }

    @Test("Fresh cycle accepted after reset")
    func freshCycleAfterReset() {
        var interpreter = MicKeyGestureInterpreter()
        #expect(interpreter.keyDown(mode: .holdToTalk) == .beginHold)
        interpreter.reset()
        #expect(interpreter.keyUp() == nil)
        #expect(interpreter.keyDown(mode: .toggle) == .toggle)
        #expect(interpreter.keyUp() == nil)
    }
}
