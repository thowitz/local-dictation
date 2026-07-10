import Foundation
import Testing
@testable import LocalDictation

@Suite("SetupSnapshot")
struct SetupSnapshotTests {
    private func base(
        microphone: SetupMicrophoneStatus = .authorized,
        accessibilityTrusted: Bool = true,
        inputMonitoringConfirmed: Bool = true,
        remapStatus: MicKeyRemapStatus = .installed,
        launchAgentStatus: LaunchAgentStatus = .loaded,
        persistenceDesired: Bool = true,
        dictation: SystemShortcutStatus = .disabled,
        siri: SystemShortcutStatus = .disabled,
        dictationConfirmed: Bool = false,
        siriConfirmed: Bool = false
    ) -> SetupSnapshot {
        SetupSnapshot(
            microphone: microphone,
            accessibilityTrusted: accessibilityTrusted,
            inputMonitoringConfirmed: inputMonitoringConfirmed,
            latestInputMonitoringFunctionalError: nil,
            remapStatus: remapStatus,
            launchAgentStatus: launchAgentStatus,
            persistenceDesired: persistenceDesired,
            expectedActive: true,
            firstRunReport: FirstRunCheckReport(
                dictationShortcut: dictation,
                siriHoldF5: siri,
                appleDictationAutoEnable: nil,
                symbolicHotKey164Enabled: nil
            ),
            dictationShortcutConfirmedOff: dictationConfirmed,
            siriHoldF5ConfirmedOff: siriConfirmed,
            openFailurePath: nil,
            actionError: nil
        )
    }

    @Test("Fixed step order matches checklist")
    func fixedStepOrder() {
        #expect(SetupStepID.allCases == [
            .microphone,
            .accessibility,
            .inputMonitoring,
            .micKeyRemap,
            .dictationShortcut,
            .siriHoldF5,
        ])
        #expect(base().stepOrder == SetupStepID.allCases)
    }

    @Test("Microphone completes only when authorized")
    func microphoneGate() {
        #expect(!base(microphone: .notRequested).isComplete(.microphone))
        #expect(!base(microphone: .denied).isComplete(.microphone))
        #expect(base(microphone: .authorized).isComplete(.microphone))
    }

    @Test("Accessibility completes only when trusted")
    func accessibilityGate() {
        #expect(!base(accessibilityTrusted: false).isComplete(.accessibility))
        #expect(base(accessibilityTrusted: true).isComplete(.accessibility))
    }

    @Test("Input Monitoring completes only when confirmed")
    func inputMonitoringGate() {
        #expect(!base(inputMonitoringConfirmed: false).isComplete(.inputMonitoring))
        #expect(base(inputMonitoringConfirmed: true).isComplete(.inputMonitoring))
    }

    @Test("Remap requires active mapping; persistence only when desired")
    func remapGate() {
        #expect(!base(remapStatus: .missing).isComplete(.micKeyRemap))
        #expect(!base(remapStatus: .probeFailed("x")).isComplete(.micKeyRemap))
        #expect(!base(launchAgentStatus: .absent, persistenceDesired: true).isComplete(.micKeyRemap))
        #expect(base(launchAgentStatus: .absent, persistenceDesired: false).isComplete(.micKeyRemap))
        #expect(base(launchAgentStatus: .loaded, persistenceDesired: true).isComplete(.micKeyRemap))
        #expect(!base(launchAgentStatus: .loaded, persistenceDesired: false).isComplete(.micKeyRemap))
    }

    @Test("Dictation completes when disabled or manually confirmed")
    func dictationGate() {
        #expect(!base(dictation: .enabled).isComplete(.dictationShortcut))
        #expect(!base(dictation: .unknown).isComplete(.dictationShortcut))
        #expect(base(dictation: .disabled).isComplete(.dictationShortcut))
        #expect(base(dictation: .enabled, dictationConfirmed: true).isComplete(.dictationShortcut))
        #expect(base(dictation: .enabled, dictationConfirmed: true).dictationProbeDisagreesWithConfirmation)
    }

    @Test("Siri completes when disabled or manually confirmed")
    func siriGate() {
        #expect(!base(siri: .unknown).isComplete(.siriHoldF5))
        #expect(base(siri: .disabled).isComplete(.siriHoldF5))
        #expect(base(siri: .unknown, siriConfirmed: true).isComplete(.siriHoldF5))
    }

    @Test("Overall completion requires every gate")
    func overallCompletion() {
        #expect(base().allRequiredComplete)
        #expect(!base(microphone: .denied).allRequiredComplete)
    }

    @Test("Microphone status mapping covers AVAuthorizationStatus cases")
    func microphoneStatusMapping() {
        #expect(SetupMicrophoneStatus.from(.authorized) == .authorized)
        #expect(SetupMicrophoneStatus.from(.notDetermined) == .notRequested)
        #expect(SetupMicrophoneStatus.from(.denied) == .denied)
        #expect(SetupMicrophoneStatus.from(.restricted) == .restricted)
    }
}
