import Foundation
import Testing
@testable import LocalDictation

@Suite("AppIdentity")
struct AppIdentityTests {
    @Test("Defaults suite and logging identity match stable bundle ID")
    func defaultsSuiteAndLoggingIdentityMatchStableBundleID() {
        #expect(AppIdentity.bundleIdentifier == "com.omcdowell.LocalDictation")
        #expect(AppIdentity.defaultsSuiteName == "com.omcdowell.LocalDictation")
        #expect(AppLog.subsystem == "com.omcdowell.LocalDictation")
    }

    @Test("Defaults store uses shared suite")
    func defaultsStoreUsesSharedSuite() {
        let defaults = AppIdentity.defaults
        let key = "test.identity.\(UUID().uuidString)"
        defaults.set(true, forKey: key)
        defer { defaults.removeObject(forKey: key) }

        let suite = UserDefaults(suiteName: "com.omcdowell.LocalDictation")
        #expect(suite != nil)
        #expect(suite!.bool(forKey: key))
        #expect(
            ObjectIdentifier(defaults as AnyObject)
                != ObjectIdentifier(UserDefaults.standard as AnyObject)
        )
    }

    @Test("Mic-key remap LaunchAgent label unchanged")
    @MainActor
    func micKeyRemapLaunchAgentLabelUnchanged() {
        #expect(MicKeyManager.launchAgentLabel == "com.local-dictation.keyremap")
    }
}
