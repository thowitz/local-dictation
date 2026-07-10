import Foundation
import Testing
@testable import LocalDictation

@Suite("MicKeyManagerParsing")
struct MicKeyManagerParsingTests {
    private let src = MicKeyManager.micKeyHIDUsage
    private let dst = MicKeyManager.f13HIDUsage

    @Test("JSON object with UserKeyMapping detects paired entry")
    func jsonObjectDetectsPairedEntry() {
        let output = """
        {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\(src),"HIDKeyboardModifierMappingDst":\(dst)}]}
        """
        #expect(MicKeyManager.userKeyMappingContainsOurRemap(output))
    }

    @Test("JSON array of mappings detects paired entry")
    func jsonArrayDetectsPairedEntry() {
        let output = """
        [{"HIDKeyboardModifierMappingSrc":\(src),"HIDKeyboardModifierMappingDst":\(dst)}]
        """
        #expect(MicKeyManager.userKeyMappingContainsOurRemap(output))
    }

    @Test("OpenStep decimal plist detects paired entry")
    func openStepDecimalDetectsPairedEntry() {
        // Typical hidutil OpenStep-style dump with decimal string values.
        let output = """
        (
                {
            HIDKeyboardModifierMappingSrc = \(src);
            HIDKeyboardModifierMappingDst = \(dst);
        }
        )
        """
        #expect(MicKeyManager.userKeyMappingContainsOurRemap(output))
    }

    @Test("Hex string values in JSON are accepted")
    func hexStringValuesAccepted() {
        let output = """
        [{"HIDKeyboardModifierMappingSrc":"0xC000000CF","HIDKeyboardModifierMappingDst":"0x700000068"}]
        """
        #expect(MicKeyManager.userKeyMappingContainsOurRemap(output))
    }

    @Test("Multiple entries still find our paired mapping")
    func multipleEntriesFindPairedMapping() {
        let output = """
        [
          {"HIDKeyboardModifierMappingSrc":1,"HIDKeyboardModifierMappingDst":2},
          {"HIDKeyboardModifierMappingSrc":\(src),"HIDKeyboardModifierMappingDst":\(dst)},
          {"HIDKeyboardModifierMappingSrc":3,"HIDKeyboardModifierMappingDst":4}
        ]
        """
        #expect(MicKeyManager.userKeyMappingContainsOurRemap(output))
    }

    @Test("Split source and destination across entries is not a match")
    func splitSourceAndDestinationIsNotAMatch() {
        let output = """
        [
          {"HIDKeyboardModifierMappingSrc":\(src),"HIDKeyboardModifierMappingDst":1},
          {"HIDKeyboardModifierMappingSrc":2,"HIDKeyboardModifierMappingDst":\(dst)}
        ]
        """
        #expect(!MicKeyManager.userKeyMappingContainsOurRemap(output))
    }

    @Test("Malformed output is not a match")
    func malformedOutputIsNotAMatch() {
        #expect(!MicKeyManager.userKeyMappingContainsOurRemap("not a plist"))
        #expect(!MicKeyManager.userKeyMappingContainsOurRemap("{"))
        #expect(!MicKeyManager.userKeyMappingContainsOurRemap(""))
    }

    @Test("Empty mapping array is missing, not a parse failure")
    func emptyMappingArrayIsMissing() {
        #expect(!MicKeyManager.userKeyMappingContainsOurRemap("[]"))
        #expect(MicKeyManager.parseUserKeyMappingEntries("[]")?.isEmpty == true)
    }
}

@Suite("MicKeyRemapStatus")
@MainActor
struct MicKeyRemapStatusTests {
    @Test("Probe failure is distinct from missing")
    func probeFailureDistinctFromMissing() {
        let manager = MicKeyManager { _, _ in
            throw MicKeyManagerError.processFailed(path: "/usr/bin/hidutil", status: 1, message: "boom")
        }
        #expect(manager.remapStatus() == .probeFailed("/usr/bin/hidutil exited 1: boom"))
        #expect(!manager.verifyRemap())
    }

    @Test("Successful get without our mapping is missing")
    func successfulGetWithoutMappingIsMissing() {
        let manager = MicKeyManager { _, _ in
            MicKeyProcessResult(terminationStatus: 0, stdout: "[]", stderr: "")
        }
        #expect(manager.remapStatus() == .missing)
    }

    @Test("Malformed probe payload is probeFailed not missing")
    func malformedPayloadIsProbeFailed() {
        let manager = MicKeyManager { _, _ in
            MicKeyProcessResult(terminationStatus: 0, stdout: "not a plist {{{", stderr: "")
        }
        guard case .probeFailed(let message) = manager.remapStatus() else {
            Issue.record("Expected probeFailed for malformed payload")
            return
        }
        #expect(!message.isEmpty)
        #expect(manager.remapStatus() != .missing)
    }

    @Test("Successful get with our mapping is installed")
    func successfulGetWithMappingIsInstalled() {
        let output = """
        [{"HIDKeyboardModifierMappingSrc":\(MicKeyManager.micKeyHIDUsage),"HIDKeyboardModifierMappingDst":\(MicKeyManager.f13HIDUsage)}]
        """
        let manager = MicKeyManager { _, _ in
            MicKeyProcessResult(terminationStatus: 0, stdout: output, stderr: "")
        }
        #expect(manager.remapStatus() == .installed)
    }
}
