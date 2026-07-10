import AppKit
import Foundation

// MARK: - Public API
//
// First-run / onboarding helpers for mic-key takeover. Integration pass should
// call `FirstRunChecks.evaluate()` before enabling the remap and surface
// `.dictationShortcut` / `.siriHoldF5` when not `.disabled`, with buttons that
// call `openDictationSettings()` / `openSiriSettings()`.
//
// Detection is best-effort via public `defaults` domains only — no private API.
// When a preference cannot be read reliably, the status is `.unknown` and the
// UI should still offer the deep-link so the user can confirm manually.

/// Whether a conflicting system shortcut appears enabled.
enum SystemShortcutStatus: Equatable, Sendable {
    /// Preference clearly indicates the shortcut is off.
    case disabled
    /// Preference clearly indicates the shortcut is still on (or auto-prompt enabled).
    case enabled
    /// Not reliably readable without private API / GUI inspection.
    case unknown
}

/// Snapshot of first-run conflicts that can steal the 🎤 / F5 key.
struct FirstRunCheckReport: Equatable, Sendable {
    /// System Settings → Keyboard → Dictation → Shortcut.
    var dictationShortcut: SystemShortcutStatus
    /// Apple Intelligence & Siri → press-and-hold for Siri (often F5 / mic).
    var siriHoldF5: SystemShortcutStatus
    /// Raw `AppleDictationAutoEnable` if present (`0` = off, `1` = on).
    var appleDictationAutoEnable: Int?
    /// Raw symbolic-hotkey 164 `enabled` flag when readable.
    var symbolicHotKey164Enabled: Bool?

    var needsUserAttention: Bool {
        dictationShortcut == .enabled
            || dictationShortcut == .unknown
            || siriHoldF5 == .enabled
            || siriHoldF5 == .unknown
    }
}

/// Detects macOS Dictation / Siri shortcut conflicts and opens the exact panes.
enum FirstRunChecks {
    /// Keyboard settings (Dictation lives under this extension on Ventura+).
    static let dictationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
    )!
    /// Apple Intelligence & Siri settings.
    static let siriSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Siri-Settings.extension"
    )!

    /// Symbolic hotkey ID historically used for the Dictation shortcut.
    private static let dictationSymbolicHotKeyID = 164

    /// Reads public preference domains and returns a conflict report.
    static func evaluate() -> FirstRunCheckReport {
        evaluate(
            appleDictationAutoEnable: readAppleDictationAutoEnable(),
            symbolicHotKey164Enabled: readSymbolicHotKey164Enabled()
        )
    }

    /// Pure evaluator for tests and callers that already have preference values.
    /// Symbolic hotkey 164 takes precedence over `AppleDictationAutoEnable`.
    /// Siri hold-F5 has no stable public probe and remains `.unknown` unless a
    /// future caller supplies an explicit disabled/enabled override.
    static func evaluate(
        appleDictationAutoEnable: Int?,
        symbolicHotKey164Enabled: Bool?,
        siriHoldF5: SystemShortcutStatus = .unknown
    ) -> FirstRunCheckReport {
        let dictation: SystemShortcutStatus = {
            // Prefer the explicit Shortcut toggle when present.
            if let symbolicHotKey164Enabled {
                return symbolicHotKey164Enabled ? .enabled : .disabled
            }
            // Fallback: AppleDictationAutoEnable — 0 means "Don't Ask Again" / Off.
            if let appleDictationAutoEnable {
                return appleDictationAutoEnable == 0 ? .disabled : .enabled
            }
            return .unknown
        }()

        return FirstRunCheckReport(
            dictationShortcut: dictation,
            siriHoldF5: siriHoldF5,
            appleDictationAutoEnable: appleDictationAutoEnable,
            symbolicHotKey164Enabled: symbolicHotKey164Enabled
        )
    }

    /// Opens System Settings → Keyboard (Dictation shortcut lives here).
    @discardableResult
    static func openDictationSettings() -> Bool {
        NSWorkspace.shared.open(dictationSettingsURL)
    }

    /// Opens System Settings → Apple Intelligence & Siri.
    @discardableResult
    static func openSiriSettings() -> Bool {
        NSWorkspace.shared.open(siriSettingsURL)
    }

    // MARK: - Preference readers

    /// `defaults read com.apple.HIToolbox AppleDictationAutoEnable`
    /// — `0` turns the Dictation shortcut / prompt off.
    private static func readAppleDictationAutoEnable() -> Int? {
        let defaults = UserDefaults(suiteName: "com.apple.HIToolbox")
        // Prefer object(forKey:) so a missing key yields nil rather than 0.
        if let number = defaults?.object(forKey: "AppleDictationAutoEnable") as? NSNumber {
            return number.intValue
        }
        // CFPreferences can see values UserDefaults suite misses for some domains.
        var exists = DarwinBoolean(false)
        let value = CFPreferencesGetAppIntegerValue(
            "AppleDictationAutoEnable" as CFString,
            "com.apple.HIToolbox" as CFString,
            &exists
        )
        return exists.boolValue ? Int(value) : nil
    }

    /// Reads `AppleSymbolicHotKeys[164].enabled` from the symbolichotkeys plist.
    /// `164` is the Dictation shortcut entry used by macOS for many years.
    private static func readSymbolicHotKey164Enabled() -> Bool? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Preferences/com.apple.symbolichotkeys.plist",
                isDirectory: false
            )
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let hotKeys = plist["AppleSymbolicHotKeys"] as? [AnyHashable: Any]
        else {
            return nil
        }

        let entry =
            hotKeys[Self.dictationSymbolicHotKeyID]
            ?? hotKeys[String(Self.dictationSymbolicHotKeyID)]
        guard let dict = entry as? [String: Any] else {
            return nil
        }

        if let enabled = dict["enabled"] as? Bool {
            return enabled
        }
        if let number = dict["enabled"] as? NSNumber {
            return number.boolValue
        }
        return nil
    }
}
