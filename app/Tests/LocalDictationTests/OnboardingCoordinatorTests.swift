import Foundation
import Testing
@testable import LocalDictation

@Suite("OnboardingCoordinator")
@MainActor
struct OnboardingCoordinatorTests {
    private final class ProbeState {
        var microphone: SetupMicrophoneStatus = .notRequested
        var accessibilityTrusted = false
        var remap: MicKeyRemapStatus = .missing
        var agent: LaunchAgentStatus = .absent
        var dictation: SystemShortcutStatus = .unknown
        var siri: SystemShortcutStatus = .unknown
        var openedURLs: [URL] = []
        var openShouldSucceed = true
        var micRequestCount = 0
        var axPromptCount = 0
        var installResult: MicKeyRemapResult = .installed
        var installCount = 0
        var installAgentCount = 0
        var removeRemapCount = 0
        var removeAgentCount = 0
        var installAgentError: Error?
        var removeAgentError: Error?
        var removeRemapError: Error?
    }

    private func makeCoordinator(
        defaults: UserDefaults,
        state: ProbeState
    ) -> OnboardingCoordinator {
        let prefs = SetupPreferences(defaults: defaults, seedValidLaunchAgent: { false })
        let deps = OnboardingDependencies(
            microphoneStatus: { state.microphone },
            requestMicrophoneAccess: {
                state.micRequestCount += 1
                state.microphone = .authorized
                return true
            },
            isAccessibilityTrusted: { state.accessibilityTrusted },
            promptAccessibility: { state.axPromptCount += 1 },
            openURL: { url in
                state.openedURLs.append(url)
                return state.openShouldSucceed
            },
            evaluateShortcuts: {
                FirstRunCheckReport(
                    dictationShortcut: state.dictation,
                    siriHoldF5: state.siri,
                    appleDictationAutoEnable: nil,
                    symbolicHotKey164Enabled: nil
                )
            },
            remapStatus: { state.remap },
            launchAgentStatus: { state.agent },
            installAndVerifyRemap: {
                state.installCount += 1
                if case .installed = state.installResult {
                    state.remap = .installed
                }
                return state.installResult
            },
            installLaunchAgent: {
                state.installAgentCount += 1
                if let error = state.installAgentError { throw error }
                state.agent = .loaded
            },
            removeRemap: {
                state.removeRemapCount += 1
                if let error = state.removeRemapError { throw error }
                state.remap = .missing
            },
            removeLaunchAgent: {
                state.removeAgentCount += 1
                if let error = state.removeAgentError { throw error }
                state.agent = .absent
            }
        )
        return OnboardingCoordinator(preferences: prefs, dependencies: deps)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "LocalDictation.OnboardingCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    @Test("Refresh reads injected probes")
    func refreshReadsProbes() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        state.microphone = .denied
        state.accessibilityTrusted = true
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        coordinator.refresh()
        #expect(coordinator.snapshot.microphone == .denied)
        #expect(coordinator.snapshot.accessibilityTrusted)
    }

    @Test("Microphone undetermined requests access; denied opens settings")
    func microphoneRoutes() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        let coordinator = makeCoordinator(defaults: defaults, state: state)

        await coordinator.performPrimaryAction(for: .microphone)
        #expect(state.micRequestCount == 1)
        #expect(coordinator.snapshot.microphone == .authorized)

        state.microphone = .denied
        await coordinator.performPrimaryAction(for: .microphone)
        #expect(state.openedURLs.last == SystemSettingsLinks.microphoneURL)
    }

    @Test("Accessibility prompts and opens settings without optimistic trust")
    func accessibilityRoute() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        await coordinator.performPrimaryAction(for: .accessibility)
        #expect(state.axPromptCount == 1)
        #expect(state.openedURLs.last == SystemSettingsLinks.accessibilityURL)
        #expect(!coordinator.snapshot.accessibilityTrusted)
    }

    @Test("Open failure surfaces manual path")
    func openFailureSurfacesPath() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        state.openShouldSucceed = false
        state.microphone = .denied
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        await coordinator.performPrimaryAction(for: .microphone)
        #expect(coordinator.snapshot.openFailurePath == SystemSettingsLinks.microphonePath)
        #expect(coordinator.snapshot.actionError?.contains("manually") == true)
    }

    @Test("Input Monitoring open does not auto-confirm; open-failure leaves unconfirmed")
    func inputMonitoringOpenDoesNotAutoConfirm() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        state.openShouldSucceed = false
        let coordinator = makeCoordinator(defaults: defaults, state: state)

        await coordinator.performPrimaryAction(for: .inputMonitoring)
        #expect(!coordinator.preferences.inputMonitoringConfirmed)
        #expect(coordinator.snapshot.openFailurePath == SystemSettingsLinks.inputMonitoringPath)
        #expect(coordinator.snapshot.actionError?.contains("manually") == true)
        #expect(!coordinator.snapshot.isComplete(.inputMonitoring))
    }

    @Test("Input Monitoring confirmation is explicit; Dictation/Siri confirmations persist")
    func confirmations() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        let coordinator = makeCoordinator(defaults: defaults, state: state)

        await coordinator.performPrimaryAction(for: .inputMonitoring)
        #expect(!coordinator.preferences.inputMonitoringConfirmed)
        #expect(state.openedURLs.contains(SystemSettingsLinks.inputMonitoringURL))

        coordinator.confirmInputMonitoring()
        #expect(coordinator.preferences.inputMonitoringConfirmed)

        coordinator.confirmDictationShortcutOff()
        coordinator.confirmSiriHoldF5Off()
        #expect(coordinator.preferences.dictationShortcutConfirmedOff)
        #expect(coordinator.preferences.siriHoldF5ConfirmedOff)
    }

    @Test("Disabling persistence removes agent; removal failure keeps remap incomplete")
    func persistenceToggleRemovalFailure() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        state.remap = .installed
        state.agent = .loaded
        state.removeAgentError = MicKeyManagerError.persistenceUnhealthy("bootout failed")
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        coordinator.preferences.persistenceDesired = true
        coordinator.preferences.expectedActive = true

        coordinator.setPersistenceDesired(false)
        #expect(state.removeAgentCount == 1)
        #expect(coordinator.preferences.persistenceDesired == false)
        #expect(coordinator.snapshot.actionError?.contains("persistence") == true)
        #expect(coordinator.snapshot.launchAgentStatus == .loaded)
        #expect(!coordinator.snapshot.isComplete(.micKeyRemap))
        #expect(!coordinator.snapshot.statusText(for: .micKeyRemap).contains("Session only"))
    }

    @Test("Enabling persistence installs agent")
    func persistenceToggleInstallsAgent() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        state.remap = .installed
        state.agent = .absent
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        coordinator.preferences.persistenceDesired = false

        coordinator.setPersistenceDesired(true)
        #expect(state.installAgentCount == 1)
        #expect(coordinator.snapshot.launchAgentStatus == .loaded)
        #expect(coordinator.snapshot.isComplete(.micKeyRemap))
    }

    @Test("Partial Remove clears expectation even when LaunchAgent removal fails")
    func partialRemoveClearsExpectation() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        state.remap = .installed
        state.agent = .loaded
        state.removeAgentError = MicKeyManagerError.processFailed(
            path: "/bin/launchctl",
            status: 1,
            message: "bootout failed"
        )
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        coordinator.preferences.markExpectedActiveAfterVerifiedInstall(persistenceDesired: true)

        coordinator.removeMicKeyRemap()
        #expect(state.removeRemapCount == 1)
        #expect(state.removeAgentCount == 1)
        #expect(!coordinator.preferences.expectedActive)
        #expect(!coordinator.preferences.persistenceDesired)
        #expect(coordinator.snapshot.actionError != nil)
    }

    @Test("Restore failure returns false and leaves actionable error")
    func restoreFailureRouting() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        state.installResult = .failed("hidutil refused")
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        coordinator.preferences.expectedActive = true
        coordinator.preferences.persistenceDesired = true

        let ok = coordinator.restoreExpectedRemap()
        #expect(!ok)
        #expect(coordinator.snapshot.actionError?.contains("hidutil refused") == true)
    }

    @Test("Repair persistence failure returns false and leaves actionable error")
    func repairPersistenceFailureRouting() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        state.installResult = .installed
        state.installAgentError = MicKeyManagerError.persistenceUnhealthy("bootstrap failed")
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        coordinator.preferences.expectedActive = true
        coordinator.preferences.persistenceDesired = true

        let ok = coordinator.restoreExpectedRemap()
        #expect(!ok)
        #expect(coordinator.snapshot.actionError?.contains("persistence repair failed") == true)
    }

    @Test("Install with persistence desired installs agent; partial success keeps incomplete")
    func installPartialSuccess() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        state.installAgentError = MicKeyManagerError.persistenceUnhealthy("bootstrap failed")
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        // Preference already desired; install path attempts agent after remap.
        coordinator.preferences.persistenceDesired = true
        await coordinator.installRemapFromSetup()
        #expect(state.installCount == 1)
        #expect(state.installAgentCount == 1)
        #expect(coordinator.preferences.expectedActive)
        #expect(coordinator.snapshot.actionError?.contains("persistence failed") == true)
        #expect(!coordinator.snapshot.isComplete(.micKeyRemap))
    }

    @Test("Session-only install removes agent and completes remap gate")
    func sessionOnlyInstall() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        state.agent = .loaded
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        coordinator.preferences.persistenceDesired = false
        await coordinator.installRemapFromSetup()
        #expect(state.removeAgentCount == 1)
        #expect(coordinator.snapshot.isComplete(.micKeyRemap))
    }

    @Test("Session-only preference with loaded agent is incomplete")
    func sessionOnlyWithLoadedAgentIncomplete() {
        let snap = SetupSnapshot(
            microphone: .authorized,
            accessibilityTrusted: true,
            inputMonitoringConfirmed: true,
            latestInputMonitoringFunctionalError: nil,
            remapStatus: .installed,
            launchAgentStatus: .loaded,
            persistenceDesired: false,
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
        #expect(!snap.isComplete(.micKeyRemap))
        #expect(!snap.statusText(for: .micKeyRemap).contains("Session only"))
    }

    @Test("Finish setup is guarded until all complete")
    func finishGuard() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        #expect(!coordinator.finishSetup())

        state.microphone = .authorized
        state.accessibilityTrusted = true
        state.remap = .installed
        state.agent = .loaded
        state.dictation = .disabled
        state.siri = .disabled
        coordinator.preferences.inputMonitoringConfirmed = true
        coordinator.preferences.persistenceDesired = true
        coordinator.refresh()
        #expect(coordinator.finishSetup())
        #expect(coordinator.preferences.isSetupComplete)
    }

    @Test("Remove clears expectation atomically")
    func removeClearsExpectation() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        state.remap = .installed
        state.agent = .loaded
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        coordinator.preferences.markExpectedActiveAfterVerifiedInstall(persistenceDesired: true)
        coordinator.removeMicKeyRemap()
        #expect(state.removeRemapCount == 1)
        #expect(state.removeAgentCount == 1)
        #expect(!coordinator.preferences.expectedActive)
        #expect(!coordinator.preferences.persistenceDesired)
    }

    @Test("Menu re-open action refreshes snapshot")
    func menuReopenRefreshes() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        state.microphone = .authorized
        coordinator.openSetupChecklist()
        #expect(coordinator.snapshot.microphone == .authorized)
    }

    @Test("Needs Input Monitoring leaves functional error on snapshot")
    func needsInputMonitoring() async {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ProbeState()
        let guidance = MicKeyInputMonitoringGuidance.forCurrentApp()
        state.installResult = .needsInputMonitoring(guidance: guidance)
        let coordinator = makeCoordinator(defaults: defaults, state: state)
        await coordinator.installRemapFromSetup()
        #expect(coordinator.snapshot.latestInputMonitoringFunctionalError == guidance.userGuidance)
        #expect(!coordinator.preferences.expectedActive)
    }
}
