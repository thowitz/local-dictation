import Foundation
import Testing
@testable import LocalDictation

@Suite("MicKeyModePreference")
struct MicKeyModePreferenceTests {
    private func isolatedDefaults() -> UserDefaults {
        let name = "LocalDictation.MicKeyModePreferenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("Failed to create isolated UserDefaults suite \(name)")
            return UserDefaults.standard
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Missing preference falls back to toggle")
    func missingFallsBackToToggle() {
        let defaults = isolatedDefaults()
        #expect(MicKeyMode.read(from: defaults) == .toggle)
    }

    @Test("Invalid raw value falls back to toggle")
    func invalidFallsBackToToggle() {
        let defaults = isolatedDefaults()
        defaults.set("not-a-mode", forKey: MicKeyMode.preferenceKey)
        #expect(MicKeyMode.read(from: defaults) == .toggle)
    }

    @Test("Both raw values round-trip through an isolated suite")
    func bothRawValuesRoundTrip() {
        let defaults = isolatedDefaults()

        MicKeyMode.write(.holdToTalk, to: defaults)
        #expect(MicKeyMode.read(from: defaults) == .holdToTalk)
        #expect(defaults.string(forKey: MicKeyMode.preferenceKey) == MicKeyMode.holdToTalk.rawValue)

        MicKeyMode.write(.toggle, to: defaults)
        #expect(MicKeyMode.read(from: defaults) == .toggle)
        #expect(defaults.string(forKey: MicKeyMode.preferenceKey) == MicKeyMode.toggle.rawValue)
    }

    @Test("Isolated suite does not pollute the app defaults suite")
    func isolatedSuiteDoesNotPolluteAppSuite() {
        let appKey = "test.micKeyMode.pollution.\(UUID().uuidString)"
        let appDefaults = AppIdentity.defaults
        // Snapshot: ensure we never write MicKeyMode.preferenceKey into the real suite.
        let before = appDefaults.object(forKey: MicKeyMode.preferenceKey)
        defer {
            if let before {
                appDefaults.set(before, forKey: MicKeyMode.preferenceKey)
            } else {
                appDefaults.removeObject(forKey: MicKeyMode.preferenceKey)
            }
            appDefaults.removeObject(forKey: appKey)
        }

        let isolated = isolatedDefaults()
        MicKeyMode.write(.holdToTalk, to: isolated)
        #expect(MicKeyMode.read(from: isolated) == .holdToTalk)

        // Real app suite must be unchanged by the isolated write.
        #expect(appDefaults.object(forKey: MicKeyMode.preferenceKey) as? String == before as? String)

        // Sanity: isolated suite is not the app suite.
        isolated.set(true, forKey: appKey)
        #expect(!appDefaults.bool(forKey: appKey))
    }

    @Test("Display titles match menu copy")
    func displayTitlesMatchMenuCopy() {
        #expect(MicKeyMode.holdToTalk.displayTitle == "Hold to Talk")
        #expect(MicKeyMode.toggle.displayTitle == "Press to Toggle")
    }
}
