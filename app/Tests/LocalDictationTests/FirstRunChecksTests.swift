import Foundation
import Testing
@testable import LocalDictation

@Suite("FirstRunChecks")
struct FirstRunChecksTests {
    @Test("Symbolic hotkey 164 enabled wins over auto-enable off")
    func symbolicHotKeyEnabledTakesPrecedence() {
        let report = FirstRunChecks.evaluate(
            appleDictationAutoEnable: 0,
            symbolicHotKey164Enabled: true
        )
        #expect(report.dictationShortcut == .enabled)
        #expect(report.symbolicHotKey164Enabled == true)
        #expect(report.appleDictationAutoEnable == 0)
    }

    @Test("Symbolic hotkey 164 disabled wins over auto-enable on")
    func symbolicHotKeyDisabledTakesPrecedence() {
        let report = FirstRunChecks.evaluate(
            appleDictationAutoEnable: 1,
            symbolicHotKey164Enabled: false
        )
        #expect(report.dictationShortcut == .disabled)
    }

    @Test("Falls back to AppleDictationAutoEnable when hotkey absent")
    func fallsBackToAutoEnable() {
        #expect(
            FirstRunChecks.evaluate(
                appleDictationAutoEnable: 0,
                symbolicHotKey164Enabled: nil
            ).dictationShortcut == .disabled
        )
        #expect(
            FirstRunChecks.evaluate(
                appleDictationAutoEnable: 1,
                symbolicHotKey164Enabled: nil
            ).dictationShortcut == .enabled
        )
    }

    @Test("Unknown when neither preference is readable")
    func unknownWhenNeitherReadable() {
        let report = FirstRunChecks.evaluate(
            appleDictationAutoEnable: nil,
            symbolicHotKey164Enabled: nil
        )
        #expect(report.dictationShortcut == .unknown)
        #expect(report.appleDictationAutoEnable == nil)
        #expect(report.symbolicHotKey164Enabled == nil)
    }

    @Test("Siri hold-F5 defaults to unknown")
    func siriDefaultsToUnknown() {
        let report = FirstRunChecks.evaluate(
            appleDictationAutoEnable: 0,
            symbolicHotKey164Enabled: false
        )
        #expect(report.siriHoldF5 == .unknown)
        #expect(report.needsUserAttention)
    }

    @Test("Dictation and Siri settings URLs match System Settings deep links")
    func settingsURLsMatchDeepLinks() {
        #expect(
            FirstRunChecks.dictationSettingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        )
        #expect(
            FirstRunChecks.siriSettingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        )
    }
}
