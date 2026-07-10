import AppKit
import AVFoundation
import Foundation
import os
import SwiftUI

// MARK: - Logging

enum OnboardingLog {
    static let logger = Logger(subsystem: AppLog.subsystem, category: "onboarding")
}

// MARK: - Steps & snapshot

enum SetupStepID: String, CaseIterable, Equatable, Sendable {
    case microphone
    case accessibility
    case inputMonitoring
    case micKeyRemap
    case dictationShortcut
    case siriHoldF5
}

enum SetupMicrophoneStatus: Equatable, Sendable {
    case authorized
    case notRequested
    case denied
    case restricted
    case unknown

    static func from(_ status: AVAuthorizationStatus) -> SetupMicrophoneStatus {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notRequested
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    var displayTitle: String {
        switch self {
        case .authorized: return "Authorized"
        case .notRequested: return "Not requested"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .unknown: return "Unknown"
        }
    }
}

/// Immutable render snapshot for the setup checklist.
struct SetupSnapshot: Equatable, Sendable {
    var microphone: SetupMicrophoneStatus
    var accessibilityTrusted: Bool
    var inputMonitoringConfirmed: Bool
    var latestInputMonitoringFunctionalError: String?
    var remapStatus: MicKeyRemapStatus
    var launchAgentStatus: LaunchAgentStatus
    var persistenceDesired: Bool
    var expectedActive: Bool
    var firstRunReport: FirstRunCheckReport
    var dictationShortcutConfirmedOff: Bool
    var siriHoldF5ConfirmedOff: Bool
    var openFailurePath: String?
    var actionError: String?

    var stepOrder: [SetupStepID] { SetupStepID.allCases }

    func isComplete(_ step: SetupStepID) -> Bool {
        switch step {
        case .microphone:
            return microphone == .authorized
        case .accessibility:
            return accessibilityTrusted
        case .inputMonitoring:
            return inputMonitoringConfirmed
        case .micKeyRemap:
            guard remapStatus == .installed else { return false }
            if persistenceDesired {
                return launchAgentStatus == .loaded
            }
            // Session-only must not leave a loaded/present app-owned agent.
            return launchAgentStatus == .absent
        case .dictationShortcut:
            return firstRunReport.dictationShortcut == .disabled || dictationShortcutConfirmedOff
        case .siriHoldF5:
            return firstRunReport.siriHoldF5 == .disabled || siriHoldF5ConfirmedOff
        }
    }

    var allRequiredComplete: Bool {
        SetupStepID.allCases.allSatisfy { isComplete($0) }
    }

    var dictationProbeDisagreesWithConfirmation: Bool {
        dictationShortcutConfirmedOff && firstRunReport.dictationShortcut == .enabled
    }

    func statusText(for step: SetupStepID) -> String {
        switch step {
        case .microphone:
            return microphone.displayTitle
        case .accessibility:
            return accessibilityTrusted ? "Trusted" : "Not trusted"
        case .inputMonitoring:
            if let latestInputMonitoringFunctionalError {
                return "Likely needs grant — \(latestInputMonitoringFunctionalError)"
            }
            return inputMonitoringConfirmed ? "Confirmed" : "Needs review"
        case .micKeyRemap:
            let mapping: String
            switch remapStatus {
            case .installed: mapping = "Mapping active"
            case .missing: mapping = "Mapping missing"
            case .probeFailed(let message): mapping = "Probe failed: \(message)"
            }
            let persistence: String
            if persistenceDesired {
                switch launchAgentStatus {
                case .loaded: persistence = "Persistence loaded"
                case .validButUnloaded: persistence = "Persistence unloaded"
                case .absent: persistence = "Persistence absent"
                case .invalid(let reason): persistence = "Persistence invalid: \(reason)"
                }
            } else {
                switch launchAgentStatus {
                case .absent:
                    persistence = "Session only"
                case .loaded:
                    persistence = "Persistence still loaded"
                case .validButUnloaded:
                    persistence = "Persistence still present (unloaded)"
                case .invalid(let reason):
                    persistence = "Persistence still present: \(reason)"
                }
            }
            return "\(mapping) · \(persistence)"
        case .dictationShortcut:
            switch firstRunReport.dictationShortcut {
            case .enabled: return dictationShortcutConfirmedOff ? "Confirmed off (probe still on)" : "Detected on"
            case .disabled: return "Appears off"
            case .unknown: return dictationShortcutConfirmedOff ? "Confirmed off" : "Could not verify"
            }
        case .siriHoldF5:
            switch firstRunReport.siriHoldF5 {
            case .disabled: return "Appears off"
            case .enabled: return siriHoldF5ConfirmedOff ? "Confirmed off (probe still on)" : "Detected on"
            case .unknown: return siriHoldF5ConfirmedOff ? "Confirmed off" : "Not automatically detectable"
            }
        }
    }
}

// MARK: - System Settings links

enum SystemSettingsLinks {
    static let microphoneURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
    )!
    static let accessibilityURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
    )!
    static let inputMonitoringURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
    )!
    static var dictationURL: URL { FirstRunChecks.dictationSettingsURL }
    static var siriURL: URL { FirstRunChecks.siriSettingsURL }

    static let microphonePath = "Privacy & Security → Microphone"
    static let accessibilityPath = "Privacy & Security → Accessibility"
    static let inputMonitoringPath = "Privacy & Security → Input Monitoring"
    static let dictationPath = "Keyboard → Dictation → Shortcut"
    static let siriPath = "Apple Intelligence & Siri → press-and-hold for Siri"

    static func manualPath(for step: SetupStepID) -> String? {
        switch step {
        case .microphone: return microphonePath
        case .accessibility: return accessibilityPath
        case .inputMonitoring: return inputMonitoringPath
        case .dictationShortcut: return dictationPath
        case .siriHoldF5: return siriPath
        case .micKeyRemap: return nil
        }
    }
}

// MARK: - Preferences

enum SetupPreferenceKey {
    static let completedVersion = "setup.completedVersion"
    static let inputMonitoringConfirmed = "setup.inputMonitoringConfirmed"
    static let dictationShortcutConfirmedOff = "setup.dictationShortcutConfirmedOff"
    static let siriHoldF5ConfirmedOff = "setup.siriHoldF5ConfirmedOff"
    static let expectedActive = "micKey.expectedActive"
    static let persistenceDesired = "micKey.persistenceDesired"
    /// Marks that the one-time LaunchAgent → expectation seed was attempted.
    static let legacyExpectationSeedAttempted = "micKey.legacyExpectationSeedAttempted"
    /// Legacy Boolean from the old first-run alert. Must not satisfy completion.
    static let legacyFirstRunChecksCompleted = "firstRunChecksCompleted"
}

@MainActor
final class SetupPreferences {
    static let currentCompletedVersion = 1

    static let completedVersionKey = SetupPreferenceKey.completedVersion
    static let inputMonitoringConfirmedKey = SetupPreferenceKey.inputMonitoringConfirmed
    static let dictationShortcutConfirmedOffKey = SetupPreferenceKey.dictationShortcutConfirmedOff
    static let siriHoldF5ConfirmedOffKey = SetupPreferenceKey.siriHoldF5ConfirmedOff
    static let expectedActiveKey = SetupPreferenceKey.expectedActive
    static let persistenceDesiredKey = SetupPreferenceKey.persistenceDesired
    static let legacyExpectationSeedAttemptedKey = SetupPreferenceKey.legacyExpectationSeedAttempted
    static let legacyFirstRunChecksCompletedKey = SetupPreferenceKey.legacyFirstRunChecksCompleted

    private let defaults: UserDefaults
    private let seedValidLaunchAgent: () -> Bool

    init(
        defaults: UserDefaults = AppIdentity.defaults,
        seedValidLaunchAgent: @escaping () -> Bool = {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("\(MicKeyManager.launchAgentLabel).plist", isDirectory: false)
            return FileManager.default.fileExists(atPath: url.path)
                && MicKeyManager.validateLaunchAgentPlist(at: url) == nil
        }
    ) {
        self.defaults = defaults
        self.seedValidLaunchAgent = seedValidLaunchAgent
        ensurePersistenceDefault()
        seedExpectationFromValidLaunchAgentIfNeeded()
    }

    var completedVersion: Int {
        defaults.integer(forKey: Self.completedVersionKey)
    }

    var isSetupComplete: Bool {
        completedVersion >= Self.currentCompletedVersion
    }

    var shouldAutoShowSetup: Bool {
        !isSetupComplete
    }

    var inputMonitoringConfirmed: Bool {
        get { defaults.bool(forKey: Self.inputMonitoringConfirmedKey) }
        set { defaults.set(newValue, forKey: Self.inputMonitoringConfirmedKey) }
    }

    var dictationShortcutConfirmedOff: Bool {
        get { defaults.bool(forKey: Self.dictationShortcutConfirmedOffKey) }
        set { defaults.set(newValue, forKey: Self.dictationShortcutConfirmedOffKey) }
    }

    var siriHoldF5ConfirmedOff: Bool {
        get { defaults.bool(forKey: Self.siriHoldF5ConfirmedOffKey) }
        set { defaults.set(newValue, forKey: Self.siriHoldF5ConfirmedOffKey) }
    }

    var expectedActive: Bool {
        get { defaults.bool(forKey: Self.expectedActiveKey) }
        set { defaults.set(newValue, forKey: Self.expectedActiveKey) }
    }

    var persistenceDesired: Bool {
        get {
            if defaults.object(forKey: Self.persistenceDesiredKey) == nil {
                return true
            }
            return defaults.bool(forKey: Self.persistenceDesiredKey)
        }
        set { defaults.set(newValue, forKey: Self.persistenceDesiredKey) }
    }

    /// Closing the window must not mark completion.
    func markFinishedIfAllowed(snapshot: SetupSnapshot) -> Bool {
        guard snapshot.allRequiredComplete else { return false }
        defaults.set(Self.currentCompletedVersion, forKey: Self.completedVersionKey)
        OnboardingLog.logger.info("Setup completed version \(Self.currentCompletedVersion)")
        return true
    }

    func clearRemapExpectation() {
        expectedActive = false
        persistenceDesired = false
    }

    func markExpectedActiveAfterVerifiedInstall(persistenceDesired desired: Bool) {
        expectedActive = true
        persistenceDesired = desired
    }

    private func ensurePersistenceDefault() {
        if defaults.object(forKey: Self.persistenceDesiredKey) == nil {
            defaults.set(true, forKey: Self.persistenceDesiredKey)
        }
    }

    private func seedExpectationFromValidLaunchAgentIfNeeded() {
        // Persist the attempt so a failed seed cannot re-fire on later launches.
        if defaults.object(forKey: Self.legacyExpectationSeedAttemptedKey) != nil {
            return
        }
        if defaults.object(forKey: Self.expectedActiveKey) != nil {
            defaults.set(true, forKey: Self.legacyExpectationSeedAttemptedKey)
            return
        }
        defaults.set(true, forKey: Self.legacyExpectationSeedAttemptedKey)
        guard seedValidLaunchAgent() else { return }
        expectedActive = true
        persistenceDesired = true
        OnboardingLog.logger.info("Seeded mic-key expectation from valid app-owned LaunchAgent")
    }
}

// MARK: - Dependencies

@MainActor
struct OnboardingDependencies {
    var microphoneStatus: () -> SetupMicrophoneStatus
    var requestMicrophoneAccess: () async -> Bool
    var isAccessibilityTrusted: () -> Bool
    var promptAccessibility: () -> Void
    var openURL: (URL) -> Bool
    var evaluateShortcuts: () -> FirstRunCheckReport
    var remapStatus: () -> MicKeyRemapStatus
    var launchAgentStatus: () -> LaunchAgentStatus
    var installAndVerifyRemap: () -> MicKeyRemapResult
    var installLaunchAgent: () throws -> Void
    var removeRemap: () throws -> Void
    var removeLaunchAgent: () throws -> Void

    static func production(micKeyManager: MicKeyManager) -> OnboardingDependencies {
        OnboardingDependencies(
            microphoneStatus: {
                SetupMicrophoneStatus.from(AudioCapture.microphoneAuthorizationStatus())
            },
            requestMicrophoneAccess: {
                await AudioCapture.requestMicrophoneAccess()
            },
            isAccessibilityTrusted: { AXIsProcessTrusted() },
            promptAccessibility: {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            },
            openURL: { NSWorkspace.shared.open($0) },
            evaluateShortcuts: { FirstRunChecks.evaluate() },
            remapStatus: { micKeyManager.remapStatus() },
            launchAgentStatus: { micKeyManager.launchAgentStatus() },
            installAndVerifyRemap: { micKeyManager.installAndVerifyRemap() },
            installLaunchAgent: { try micKeyManager.installLaunchAgent() },
            removeRemap: { try micKeyManager.removeRemap() },
            removeLaunchAgent: { try micKeyManager.removeLaunchAgent() }
        )
    }
}

// MARK: - Coordinator

@MainActor
final class OnboardingCoordinator: ObservableObject {
    @Published private(set) var snapshot: SetupSnapshot
    @Published private(set) var isBusy = false
    @Published var mutationInProgress = false

    let preferences: SetupPreferences
    private let deps: OnboardingDependencies
    private var latestInputMonitoringFunctionalError: String?

    init(
        preferences: SetupPreferences,
        dependencies: OnboardingDependencies
    ) {
        self.preferences = preferences
        self.deps = dependencies
        self.snapshot = Self.makeSnapshot(
            preferences: preferences,
            dependencies: dependencies,
            latestInputMonitoringFunctionalError: nil,
            openFailurePath: nil,
            actionError: nil
        )
    }

    func refresh() {
        snapshot = Self.makeSnapshot(
            preferences: preferences,
            dependencies: deps,
            latestInputMonitoringFunctionalError: latestInputMonitoringFunctionalError,
            openFailurePath: nil,
            actionError: nil
        )
        OnboardingLog.logger.debug("Setup snapshot refreshed")
    }

    func openSetupChecklist() {
        refresh()
    }

    func finishSetup() -> Bool {
        refresh()
        return preferences.markFinishedIfAllowed(snapshot: snapshot)
    }

    func setPersistenceDesired(_ desired: Bool) {
        mutationInProgress = true
        defer { mutationInProgress = false }

        preferences.persistenceDesired = desired
        if desired {
            do {
                try deps.installLaunchAgent()
                refresh()
            } catch {
                publishActionError(
                    "Could not enable login persistence: \(error.localizedDescription)"
                )
            }
        } else {
            do {
                try deps.removeLaunchAgent()
                refresh()
            } catch {
                publishActionError(
                    "Could not remove login persistence: \(error.localizedDescription)"
                )
            }
        }
    }

    func confirmInputMonitoring() {
        preferences.inputMonitoringConfirmed = true
        refresh()
    }

    func confirmDictationShortcutOff() {
        preferences.dictationShortcutConfirmedOff = true
        refresh()
    }

    func confirmSiriHoldF5Off() {
        preferences.siriHoldF5ConfirmedOff = true
        refresh()
    }

    func performPrimaryAction(for step: SetupStepID) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        switch step {
        case .microphone:
            await handleMicrophoneAction()
        case .accessibility:
            handleAccessibilityAction()
        case .inputMonitoring:
            // Open only — confirmation is explicit via confirmInputMonitoring().
            if openSettings(
                SystemSettingsLinks.inputMonitoringURL,
                path: SystemSettingsLinks.inputMonitoringPath
            ) {
                refresh()
            }
        case .micKeyRemap:
            await installRemapFromSetup()
        case .dictationShortcut:
            openSettings(SystemSettingsLinks.dictationURL, path: SystemSettingsLinks.dictationPath)
        case .siriHoldF5:
            openSettings(SystemSettingsLinks.siriURL, path: SystemSettingsLinks.siriPath)
        }
    }

    func installRemapFromSetup() async {
        mutationInProgress = true
        defer { mutationInProgress = false }

        let result = deps.installAndVerifyRemap()
        switch result {
        case .installed:
            latestInputMonitoringFunctionalError = nil
            preferences.markExpectedActiveAfterVerifiedInstall(
                persistenceDesired: preferences.persistenceDesired
            )
            if preferences.persistenceDesired {
                do {
                    try deps.installLaunchAgent()
                } catch {
                    publishActionError(
                        "Remap is active, but login persistence failed: \(error.localizedDescription)"
                    )
                    return
                }
            } else {
                do {
                    try deps.removeLaunchAgent()
                } catch {
                    publishActionError(
                        "Remap is active, but login persistence could not be removed: \(error.localizedDescription)"
                    )
                    return
                }
            }
            refresh()
        case .needsInputMonitoring(let guidance):
            latestInputMonitoringFunctionalError = guidance.userGuidance
            publishActionError(guidance.userGuidance)
        case .failed(let message):
            publishActionError(message)
        }
    }

    func removeMicKeyRemap() {
        mutationInProgress = true
        defer { mutationInProgress = false }

        // Clear persisted intent first so a later restore cannot fire after explicit Remove.
        preferences.clearRemapExpectation()
        latestInputMonitoringFunctionalError = nil

        var errors: [String] = []
        do {
            try deps.removeRemap()
        } catch {
            errors.append(error.localizedDescription)
        }
        do {
            try deps.removeLaunchAgent()
        } catch {
            errors.append(error.localizedDescription)
        }

        if errors.isEmpty {
            refresh()
        } else {
            publishActionError(errors.joined(separator: "; "))
        }
    }

    /// Restores the expected remap (and persistence when desired).
    /// Returns `false` when an actionable error remains for the caller to surface.
    @discardableResult
    func restoreExpectedRemap() -> Bool {
        mutationInProgress = true
        defer { mutationInProgress = false }
        guard preferences.expectedActive else { return true }

        let result = deps.installAndVerifyRemap()
        switch result {
        case .installed:
            latestInputMonitoringFunctionalError = nil
            if preferences.persistenceDesired {
                do {
                    try deps.installLaunchAgent()
                } catch {
                    publishActionError(
                        "Mapping restored, but persistence repair failed: \(error.localizedDescription)"
                    )
                    return false
                }
            }
            refresh()
            return true
        case .needsInputMonitoring(let guidance):
            latestInputMonitoringFunctionalError = guidance.userGuidance
            publishActionError(guidance.userGuidance)
            return false
        case .failed(let message):
            publishActionError(message)
            return false
        }
    }

    private func handleMicrophoneAction() async {
        switch deps.microphoneStatus() {
        case .notRequested:
            _ = await deps.requestMicrophoneAccess()
            refresh()
        case .denied, .restricted, .unknown, .authorized:
            if openSettings(SystemSettingsLinks.microphoneURL, path: SystemSettingsLinks.microphonePath) {
                refresh()
            }
        }
    }

    private func handleAccessibilityAction() {
        if !deps.isAccessibilityTrusted() {
            deps.promptAccessibility()
        }
        if openSettings(SystemSettingsLinks.accessibilityURL, path: SystemSettingsLinks.accessibilityPath) {
            // Never optimistically mark trusted; refresh later on activation.
            refresh()
        }
    }

    @discardableResult
    private func openSettings(_ url: URL, path: String) -> Bool {
        let opened = deps.openURL(url)
        if !opened {
            snapshot = Self.makeSnapshot(
                preferences: preferences,
                dependencies: deps,
                latestInputMonitoringFunctionalError: latestInputMonitoringFunctionalError,
                openFailurePath: path,
                actionError: "Could not open System Settings. Open \(path) manually."
            )
            OnboardingLog.logger.error("Failed to open settings URL for \(path, privacy: .public)")
            return false
        }
        return true
    }

    private func publishActionError(_ message: String) {
        snapshot = Self.makeSnapshot(
            preferences: preferences,
            dependencies: deps,
            latestInputMonitoringFunctionalError: latestInputMonitoringFunctionalError,
            openFailurePath: nil,
            actionError: message
        )
    }

    private static func makeSnapshot(
        preferences: SetupPreferences,
        dependencies: OnboardingDependencies,
        latestInputMonitoringFunctionalError: String?,
        openFailurePath: String?,
        actionError: String?
    ) -> SetupSnapshot {
        SetupSnapshot(
            microphone: dependencies.microphoneStatus(),
            accessibilityTrusted: dependencies.isAccessibilityTrusted(),
            inputMonitoringConfirmed: preferences.inputMonitoringConfirmed,
            latestInputMonitoringFunctionalError: latestInputMonitoringFunctionalError,
            remapStatus: dependencies.remapStatus(),
            launchAgentStatus: dependencies.launchAgentStatus(),
            persistenceDesired: preferences.persistenceDesired,
            expectedActive: preferences.expectedActive,
            firstRunReport: dependencies.evaluateShortcuts(),
            dictationShortcutConfirmedOff: preferences.dictationShortcutConfirmedOff,
            siriHoldF5ConfirmedOff: preferences.siriHoldF5ConfirmedOff,
            openFailurePath: openFailurePath,
            actionError: actionError
        )
    }
}
