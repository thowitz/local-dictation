import Foundation
import os

/// Stable application identity shared by defaults, logging, and (later) packaging.
enum AppIdentity {
    /// Bundle / defaults / logging identity. Must match the future Info.plist CFBundleIdentifier (#5).
    static let bundleIdentifier = "com.omcdowell.LocalDictation"

    /// Explicit defaults suite for current and future preferences.
    static let defaultsSuiteName = bundleIdentifier

    /// Suite-backed defaults store. Never use `UserDefaults.standard` for app prefs.
    static var defaults: UserDefaults {
        // suiteName is non-nil for a valid reverse-DNS name; fall back only if the OS rejects it.
        UserDefaults(suiteName: defaultsSuiteName) ?? .standard
    }
}

enum AppLog {
    static let subsystem = AppIdentity.bundleIdentifier

    static let general = Logger(subsystem: subsystem, category: "app")
    static let server = Logger(subsystem: subsystem, category: "server")
    static let realtime = Logger(subsystem: subsystem, category: "realtime")
    static let audio = Logger(subsystem: subsystem, category: "audio")
}
