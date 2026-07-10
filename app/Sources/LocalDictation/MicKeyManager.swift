import Foundation
import os

// MARK: - Public API (wired from App.swift)
//
// `MicKeyManager` owns the 🎤 → F13 hidutil remap and LaunchAgent persistence.
// Carbon hotkeys (F13 toggle, Esc cancel, ⌥⌘D) live in App.swift's `CarbonHotKey`
// helper — one registration mechanism for the whole app.
//
//   let mic = MicKeyManager()
//   switch mic.installRemap() {
//   case .installed: …                 // mapping verified present
//   case .needsInputMonitoring(let g): // show g.userGuidance, open g.settingsURL
//   case .failed(let message): …
//   }
//   try mic.installLaunchAgent()       // persist remap across reboot
//   mic.removeRemap(); try mic.removeLaunchAgent()
//
// Constants: mic HID 0xC000000CF → F13 0x700000068; Carbon keycode 105 (kVK_F13).

/// Outcome of installing (or verifying) the mic-key → F13 `hidutil` remap.
enum MicKeyRemapResult: Equatable, Sendable {
    /// Remap is present in `UserKeyMapping`.
    case installed
    /// `hidutil` ran but the mapping is missing — typical macOS 15+ failure when
    /// the invoking binary lacks Input Monitoring.
    case needsInputMonitoring(guidance: MicKeyInputMonitoringGuidance)
    /// Process launch / parse failure unrelated to the silent-permission case.
    case failed(String)
}

/// Copy + deep-link for the Input Monitoring grant prompt.
struct MicKeyInputMonitoringGuidance: Equatable, Sendable {
    /// Human-readable instruction for an alert / menu row.
    var userGuidance: String
    /// Opens Privacy & Security → Input Monitoring.
    var settingsURL: URL

    static func forCurrentApp() -> MicKeyInputMonitoringGuidance {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        let displayName = name.isEmpty ? "LocalDictation" : name
        return MicKeyInputMonitoringGuidance(
            userGuidance:
                "Grant Input Monitoring to \(displayName) in Privacy & Security, then retry. "
                + "On macOS 15+, hidutil silently fails to apply UserKeyMapping without it.",
            settingsURL: URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
            )!
        )
    }
}

/// Remaps the hardware 🎤 / Voice Command key to F13 and persists that remap
/// via a LaunchAgent. Hotkey registration is owned by `CarbonHotKey` in App.swift.
@MainActor
final class MicKeyManager {
    // MARK: HID / LaunchAgent constants

    /// Consumer Page 0x0C usage 0xCF ("Voice Command") — the F5 mic key.
    static let micKeyHIDUsage: UInt64 = 0xC000000CF
    /// Keyboard page usage for F13.
    static let f13HIDUsage: UInt64 = 0x700000068
    /// Carbon virtual key code for F13 (`kVK_F13`).
    static let f13KeyCode: UInt32 = 105
    static let launchAgentLabel = "com.local-dictation.keyremap"
    static let hidutilPath = "/usr/bin/hidutil"

    private static let log = Logger(
        subsystem: AppLog.subsystem,
        category: "MicKeyManager"
    )

    private static let remapJSON =
        #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xC000000CF,"HIDKeyboardModifierMappingDst":0x700000068}]}"#
    private static let clearJSON = #"{"UserKeyMapping":[]}"#

    // MARK: - Remap (hidutil)

    /// Maps 🎤 (`0xC000000CF`) → F13 (`0x700000068`), then verifies the mapping.
    @discardableResult
    func installRemap() -> MicKeyRemapResult {
        do {
            _ = try runHidutil(arguments: ["property", "--set", Self.remapJSON])
        } catch {
            Self.log.error("hidutil set failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }

        if verifyRemap() {
            return .installed
        }

        let guidance = MicKeyInputMonitoringGuidance.forCurrentApp()
        Self.log.error("UserKeyMapping missing after set — likely needs Input Monitoring")
        return .needsInputMonitoring(guidance: guidance)
    }

    /// Clears all `UserKeyMapping` entries (restores stock mic-key behavior).
    func removeRemap() throws {
        _ = try runHidutil(arguments: ["property", "--set", Self.clearJSON])
    }

    /// Returns `true` when our mic→F13 mapping is present in `UserKeyMapping`.
    func verifyRemap() -> Bool {
        let output: String
        do {
            output = try runHidutil(arguments: ["property", "--get", "UserKeyMapping"])
        } catch {
            Self.log.error("hidutil get failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return Self.userKeyMappingContainsOurRemap(output)
    }

    /// Install + verify in one call (alias of `installRemap()` for call-site clarity).
    @discardableResult
    func installAndVerifyRemap() -> MicKeyRemapResult {
        installRemap()
    }

    // MARK: - LaunchAgent persistence

    var launchAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.launchAgentLabel).plist", isDirectory: false)
    }

    /// Writes `~/Library/LaunchAgents/com.local-dictation.keyremap.plist` and
    /// bootstraps it for the current GUI session (`RunAtLoad`).
    func installLaunchAgent() throws {
        let fm = FileManager.default
        let dir = launchAgentPlistURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": Self.launchAgentLabel,
            "RunAtLoad": true,
            "ProgramArguments": [
                Self.hidutilPath,
                "property",
                "--set",
                Self.remapJSON,
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: launchAgentPlistURL, options: .atomic)

        let uid = getuid()
        let domain = "gui/\(uid)"
        // bootout first so re-install is idempotent (ignore failure if not loaded).
        _ = try? runProcess(
            path: "/bin/launchctl",
            arguments: ["bootout", "\(domain)/\(Self.launchAgentLabel)"]
        )
        _ = try runProcess(
            path: "/bin/launchctl",
            arguments: ["bootstrap", domain, launchAgentPlistURL.path]
        )
    }

    /// Boots out the agent and deletes the plist.
    func removeLaunchAgent() throws {
        let uid = getuid()
        let domain = "gui/\(uid)"
        _ = try? runProcess(
            path: "/bin/launchctl",
            arguments: ["bootout", "\(domain)/\(Self.launchAgentLabel)"]
        )
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgentPlistURL.path) {
            try fm.removeItem(at: launchAgentPlistURL)
        }
    }

    func isLaunchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
    }

    // MARK: - Parsing

    /// Accepts both `hidutil` OpenStep-style dumps and JSON.
    static func userKeyMappingContainsOurRemap(_ output: String) -> Bool {
        let normalized = output
            .replacingOccurrences(of: "0x", with: "0x", options: .caseInsensitive)
            .lowercased()

        let srcHex = String(format: "0x%llx", micKeyHIDUsage)
        let dstHex = String(format: "0x%llx", f13HIDUsage)
        let srcDec = String(micKeyHIDUsage)
        let dstDec = String(f13HIDUsage)

        let hasSrc = normalized.contains(srcHex) || normalized.contains(srcDec)
        let hasDst = normalized.contains(dstHex) || normalized.contains(dstDec)
        if hasSrc && hasDst {
            return true
        }

        // JSON path: try to decode an array of mapping dicts if present.
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            let mappings: [[String: Any]]
            if let dict = json as? [String: Any],
               let arr = dict["UserKeyMapping"] as? [[String: Any]] {
                mappings = arr
            } else if let arr = json as? [[String: Any]] {
                mappings = arr
            } else {
                mappings = []
            }
            for entry in mappings {
                let src = Self.uint64(from: entry["HIDKeyboardModifierMappingSrc"])
                let dst = Self.uint64(from: entry["HIDKeyboardModifierMappingDst"])
                if src == micKeyHIDUsage && dst == f13HIDUsage {
                    return true
                }
            }
        }

        return false
    }

    private static func uint64(from value: Any?) -> UInt64? {
        switch value {
        case let n as UInt64:
            return n
        case let n as Int:
            return UInt64(bitPattern: Int64(n))
        case let n as NSNumber:
            return n.uint64Value
        case let s as String:
            if s.lowercased().hasPrefix("0x"),
               let v = UInt64(s.dropFirst(2), radix: 16) {
                return v
            }
            return UInt64(s)
        default:
            return nil
        }
    }

    // MARK: - Process helpers

    private func runHidutil(arguments: [String]) throws -> String {
        try runProcess(path: Self.hidutilPath, arguments: arguments)
    }

    @discardableResult
    private func runProcess(path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = err.isEmpty ? out : err
            throw MicKeyManagerError.processFailed(
                path: path,
                status: process.terminationStatus,
                message: detail.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return out
    }
}

enum MicKeyManagerError: Error, LocalizedError {
    case processFailed(path: String, status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let path, let status, let message):
            let suffix = message.isEmpty ? "" : ": \(message)"
            return "\(path) exited \(status)\(suffix)"
        }
    }
}
