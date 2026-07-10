import Foundation
import Testing
@testable import LocalDictation

@Suite("SetupPreferences")
@MainActor
struct SetupPreferencesTests {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "LocalDictation.SetupPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private func completeSnapshot(persistenceDesired: Bool = true) -> SetupSnapshot {
        SetupSnapshot(
            microphone: .authorized,
            accessibilityTrusted: true,
            inputMonitoringConfirmed: true,
            latestInputMonitoringFunctionalError: nil,
            remapStatus: .installed,
            launchAgentStatus: persistenceDesired ? .loaded : .absent,
            persistenceDesired: persistenceDesired,
            expectedActive: true,
            firstRunReport: FirstRunCheckReport(
                dictationShortcut: .disabled,
                siriHoldF5: .disabled,
                appleDictationAutoEnable: 0,
                symbolicHotKey164Enabled: false
            ),
            dictationShortcutConfirmedOff: false,
            siriHoldF5ConfirmedOff: false,
            openFailurePath: nil,
            actionError: nil
        )
    }

    @Test("Defaults persistence desired to true and incomplete version")
    func defaultsAndVersion() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = SetupPreferences(defaults: defaults, seedValidLaunchAgent: { false })
        #expect(prefs.persistenceDesired)
        #expect(prefs.completedVersion == 0)
        #expect(prefs.shouldAutoShowSetup)
        #expect(!prefs.isSetupComplete)
    }

    @Test("Close does not complete; guarded finish writes version 1")
    func closeVersusFinish() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = SetupPreferences(defaults: defaults, seedValidLaunchAgent: { false })

        let incomplete = completeSnapshot()
        // Simulate "close" — no markFinished call leaves version unset.
        #expect(prefs.shouldAutoShowSetup)

        #expect(prefs.markFinishedIfAllowed(snapshot: incomplete))
        #expect(prefs.completedVersion == SetupPreferences.currentCompletedVersion)
        #expect(!prefs.shouldAutoShowSetup)

        let blocked = SetupPreferences(defaults: defaults, seedValidLaunchAgent: { false })
        var incompleteSnap = completeSnapshot()
        // Force incomplete by clearing confirmation path via unauthorized mic.
        incompleteSnap = SetupSnapshot(
            microphone: .denied,
            accessibilityTrusted: true,
            inputMonitoringConfirmed: true,
            latestInputMonitoringFunctionalError: nil,
            remapStatus: .installed,
            launchAgentStatus: .loaded,
            persistenceDesired: true,
            expectedActive: true,
            firstRunReport: incompleteSnap.firstRunReport,
            dictationShortcutConfirmedOff: false,
            siriHoldF5ConfirmedOff: false,
            openFailurePath: nil,
            actionError: nil
        )
        #expect(!blocked.markFinishedIfAllowed(snapshot: incompleteSnap))
        #expect(blocked.completedVersion == SetupPreferences.currentCompletedVersion)
    }

    @Test("Legacy firstRunChecksCompleted does not satisfy completion")
    func legacyBooleanIgnored() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: SetupPreferenceKey.legacyFirstRunChecksCompleted)
        let prefs = SetupPreferences(defaults: defaults, seedValidLaunchAgent: { false })
        #expect(prefs.shouldAutoShowSetup)
        #expect(prefs.completedVersion == 0)
    }

    @Test("Expected active set only after verified install; remove clears both")
    func expectationSemantics() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = SetupPreferences(defaults: defaults, seedValidLaunchAgent: { false })
        #expect(!prefs.expectedActive)

        prefs.markExpectedActiveAfterVerifiedInstall(persistenceDesired: false)
        #expect(prefs.expectedActive)
        #expect(!prefs.persistenceDesired)

        prefs.clearRemapExpectation()
        #expect(!prefs.expectedActive)
        #expect(!prefs.persistenceDesired)
    }

    @Test("Valid LaunchAgent seeds expectation and persistence once")
    func validAgentSeed() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var seedCalls = 0
        let prefs = SetupPreferences(defaults: defaults, seedValidLaunchAgent: {
            seedCalls += 1
            return true
        })
        #expect(prefs.expectedActive)
        #expect(prefs.persistenceDesired)
        #expect(seedCalls == 1)

        // Already seeded — constructing again must not re-seed over explicit false.
        prefs.clearRemapExpectation()
        let again = SetupPreferences(defaults: defaults, seedValidLaunchAgent: { true })
        #expect(!again.expectedActive)
        #expect(!again.persistenceDesired)
    }

    @Test("Failed seed attempt is persisted; later valid agent is not retrospectively seeded")
    func failedSeedAttemptNotRetrospective() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var agentExists = false
        let first = SetupPreferences(defaults: defaults, seedValidLaunchAgent: { agentExists })
        #expect(!first.expectedActive)
        #expect(defaults.object(forKey: SetupPreferenceKey.legacyExpectationSeedAttempted) != nil)

        agentExists = true
        let second = SetupPreferences(defaults: defaults, seedValidLaunchAgent: { agentExists })
        #expect(!second.expectedActive)
        #expect(defaults.bool(forKey: SetupPreferenceKey.expectedActive) == false)
        #expect(defaults.object(forKey: SetupPreferenceKey.expectedActive) == nil)
    }

    @Test("System settings deep links match required URLs")
    func systemSettingsLinks() {
        #expect(
            SystemSettingsLinks.microphoneURL.absoluteString
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        )
        #expect(
            SystemSettingsLinks.accessibilityURL.absoluteString
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        )
        #expect(
            SystemSettingsLinks.inputMonitoringURL.absoluteString
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
        )
        #expect(SystemSettingsLinks.dictationURL == FirstRunChecks.dictationSettingsURL)
        #expect(SystemSettingsLinks.siriURL == FirstRunChecks.siriSettingsURL)
        #expect(SystemSettingsLinks.microphonePath == "Privacy & Security → Microphone")
        #expect(SystemSettingsLinks.siriPath.contains("press-and-hold for Siri"))
    }
}
