import Foundation
import os

// MARK: - Public API (wired from App.swift)
//
// `MicKeyManager` owns the 🎤 → F13 hidutil remap and LaunchAgent persistence.
// Carbon hotkeys (F13 hold/toggle per Mic Key Mode, Esc cancel, ⌥⌘D toggle) live in
// App.swift's `CarbonHotKey` helper — one registration mechanism for the whole app.
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

/// Authoritative non-mutating remap probe result.
enum MicKeyRemapStatus: Equatable, Sendable {
    case installed
    case missing
    case probeFailed(String)
}

/// App-owned LaunchAgent health for `com.local-dictation.keyremap`.
enum LaunchAgentStatus: Equatable, Sendable {
    case absent
    case invalid(String)
    case validButUnloaded
    case loaded
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
            settingsURL: SystemSettingsLinks.inputMonitoringURL
        )
    }
}

/// Narrow injectable runner for hidutil / launchctl probes and mutations.
struct MicKeyProcessResult: Equatable, Sendable {
    var terminationStatus: Int32
    var stdout: String
    var stderr: String
}

typealias MicKeyProcessRunner = @Sendable (_ path: String, _ arguments: [String]) throws -> MicKeyProcessResult

/// Remaps the hardware 🎤 / Voice Command key to F13 and persists that remap
/// via a LaunchAgent. Hotkey registration is owned by `CarbonHotKey` in App.swift.
@MainActor
final class MicKeyManager {
    // MARK: HID / LaunchAgent constants

    /// Consumer Page 0x0C usage 0xCF ("Voice Command") — the F5 mic key.
    nonisolated static let micKeyHIDUsage: UInt64 = 0xC000000CF
    /// Keyboard page usage for F13.
    nonisolated static let f13HIDUsage: UInt64 = 0x700000068
    /// Carbon virtual key code for F13 (`kVK_F13`).
    nonisolated static let f13KeyCode: UInt32 = 105
    nonisolated static let launchAgentLabel = "com.local-dictation.keyremap"
    nonisolated static let hidutilPath = "/usr/bin/hidutil"
    nonisolated static let launchctlPath = "/bin/launchctl"

    private static let log = Logger(
        subsystem: AppLog.subsystem,
        category: "MicKeyManager"
    )

    nonisolated static let remapJSON =
        #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xC000000CF,"HIDKeyboardModifierMappingDst":0x700000068}]}"#
    private static let clearJSON = #"{"UserKeyMapping":[]}"#

    private let runProcess: MicKeyProcessRunner
    private let fileManager: FileManager
    private let homeDirectory: () -> URL
    private let currentUID: () -> uid_t

    init(
        runProcess: @escaping MicKeyProcessRunner = { path, arguments in
            try MicKeyManager.runProcessUnisolated(path: path, arguments: arguments)
        },
        fileManager: FileManager = .default,
        homeDirectory: @escaping () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        currentUID: @escaping () -> uid_t = { getuid() }
    ) {
        self.runProcess = runProcess
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.currentUID = currentUID
    }

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

        switch remapStatus() {
        case .installed:
            return .installed
        case .missing:
            let guidance = MicKeyInputMonitoringGuidance.forCurrentApp()
            Self.log.error("UserKeyMapping missing after set — likely needs Input Monitoring")
            return .needsInputMonitoring(guidance: guidance)
        case .probeFailed(let message):
            return .failed(message)
        }
    }

    /// Clears all `UserKeyMapping` entries (restores stock mic-key behavior).
    func removeRemap() throws {
        _ = try runHidutil(arguments: ["property", "--set", Self.clearJSON])
    }

    /// Authoritative remap probe. Distinguishes missing from probe failure.
    func remapStatus() -> MicKeyRemapStatus {
        let output: String
        do {
            output = try runHidutil(arguments: ["property", "--get", "UserKeyMapping"])
        } catch {
            Self.log.error("hidutil get failed: \(error.localizedDescription, privacy: .public)")
            return .probeFailed(error.localizedDescription)
        }
        guard let entries = Self.parseUserKeyMappingEntries(output) else {
            Self.log.error("UserKeyMapping output unreadable")
            return .probeFailed("Unreadable UserKeyMapping output")
        }
        for entry in entries {
            let src = Self.uint64(from: entry["HIDKeyboardModifierMappingSrc"])
            let dst = Self.uint64(from: entry["HIDKeyboardModifierMappingDst"])
            if src == Self.micKeyHIDUsage && dst == Self.f13HIDUsage {
                return .installed
            }
        }
        return .missing
    }

    /// Returns `true` when our mic→F13 mapping is present in `UserKeyMapping`.
    func verifyRemap() -> Bool {
        remapStatus() == .installed
    }

    /// Install + verify in one call (alias of `installRemap()` for call-site clarity).
    @discardableResult
    func installAndVerifyRemap() -> MicKeyRemapResult {
        installRemap()
    }

    // MARK: - LaunchAgent persistence

    var launchAgentPlistURL: URL {
        homeDirectory()
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.launchAgentLabel).plist", isDirectory: false)
    }

    /// Writes `~/Library/LaunchAgents/com.local-dictation.keyremap.plist` and
    /// bootstraps it for the current GUI session (`RunAtLoad`).
    func installLaunchAgent() throws {
        let dir = launchAgentPlistURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

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

        let uid = currentUID()
        let domain = "gui/\(uid)"
        // bootout first so re-install is idempotent (ignore failure if not loaded).
        _ = try? runCheckedProcess(
            path: Self.launchctlPath,
            arguments: ["bootout", "\(domain)/\(Self.launchAgentLabel)"]
        )
        _ = try runCheckedProcess(
            path: Self.launchctlPath,
            arguments: ["bootstrap", domain, launchAgentPlistURL.path]
        )

        switch launchAgentStatus() {
        case .loaded:
            return
        case .absent:
            throw MicKeyManagerError.persistenceUnhealthy("LaunchAgent plist missing after install")
        case .invalid(let reason):
            throw MicKeyManagerError.persistenceUnhealthy(reason)
        case .validButUnloaded:
            throw MicKeyManagerError.persistenceUnhealthy(
                "LaunchAgent plist is valid but not loaded in launchd"
            )
        }
    }

    /// Boots out the agent and deletes the plist.
    func removeLaunchAgent() throws {
        let uid = currentUID()
        let domain = "gui/\(uid)"
        _ = try? runCheckedProcess(
            path: Self.launchctlPath,
            arguments: ["bootout", "\(domain)/\(Self.launchAgentLabel)"]
        )
        if fileManager.fileExists(atPath: launchAgentPlistURL.path) {
            try fileManager.removeItem(at: launchAgentPlistURL)
        }
    }

    func isLaunchAgentInstalled() -> Bool {
        fileManager.fileExists(atPath: launchAgentPlistURL.path)
    }

    /// Validates the app-owned plist and whether launchd has loaded the job.
    /// A successful `launchctl print` means loaded even when the one-shot job is not running.
    func launchAgentStatus() -> LaunchAgentStatus {
        let url = launchAgentPlistURL
        guard fileManager.fileExists(atPath: url.path) else {
            return .absent
        }

        if let reason = Self.validateLaunchAgentPlist(at: url, fileManager: fileManager) {
            return .invalid(reason)
        }

        let uid = currentUID()
        let domain = "gui/\(uid)"
        do {
            let result = try runProcess(
                Self.launchctlPath,
                ["print", "\(domain)/\(Self.launchAgentLabel)"]
            )
            if result.terminationStatus == 0 {
                return .loaded
            }
            return .validButUnloaded
        } catch {
            return .validButUnloaded
        }
    }

    // MARK: - Parsing

    /// Accepts both `hidutil` OpenStep-style dumps and JSON.
    /// Requires source and destination in the same mapping entry.
    nonisolated static func userKeyMappingContainsOurRemap(_ output: String) -> Bool {
        guard let entries = parseUserKeyMappingEntries(output) else {
            return false
        }
        for entry in entries {
            let src = uint64(from: entry["HIDKeyboardModifierMappingSrc"])
            let dst = uint64(from: entry["HIDKeyboardModifierMappingDst"])
            if src == micKeyHIDUsage && dst == f13HIDUsage {
                return true
            }
        }
        return false
    }

    /// Parses JSON or OpenStep plist `UserKeyMapping` output into entry dictionaries.
    /// Returns `nil` when the payload cannot be parsed as a mapping list.
    nonisolated static func parseUserKeyMappingEntries(_ output: String) -> [[String: Any]]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let dict = json as? [String: Any] {
                if let arr = dict["UserKeyMapping"] as? [[String: Any]] {
                    return arr
                }
                if dict["HIDKeyboardModifierMappingSrc"] != nil
                    || dict["HIDKeyboardModifierMappingDst"] != nil
                {
                    return [dict]
                }
            } else if let arr = json as? [[String: Any]] {
                return arr
            }
        }

        if let data = trimmed.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
           )
        {
            if let arr = plist as? [[String: Any]] {
                return arr
            }
            if let dict = plist as? [String: Any] {
                if let arr = dict["UserKeyMapping"] as? [[String: Any]] {
                    return arr
                }
                if dict["HIDKeyboardModifierMappingSrc"] != nil
                    || dict["HIDKeyboardModifierMappingDst"] != nil
                {
                    return [dict]
                }
            }
            if let arr = plist as? [Any] {
                return arr.compactMap { $0 as? [String: Any] }
            }
        }

        return nil
    }

    /// Returns a validation failure reason, or `nil` when the plist is app-owned and valid.
    nonisolated static func validateLaunchAgentPlist(
        at url: URL,
        fileManager: FileManager = .default
    ) -> String? {
        guard fileManager.fileExists(atPath: url.path) else {
            return "LaunchAgent plist is missing"
        }
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any]
        else {
            return "LaunchAgent plist is unreadable"
        }

        guard let label = plist["Label"] as? String, label == launchAgentLabel else {
            return "LaunchAgent Label must be \(launchAgentLabel)"
        }
        guard let runAtLoad = plist["RunAtLoad"] as? Bool, runAtLoad else {
            return "LaunchAgent RunAtLoad must be true"
        }
        guard let args = plist["ProgramArguments"] as? [String],
              args.count == 4,
              args[0] == hidutilPath,
              args[1] == "property",
              args[2] == "--set",
              args[3] == remapJSON
        else {
            return "LaunchAgent ProgramArguments must run hidutil with the mic→F13 mapping"
        }
        return nil
    }

    nonisolated static func uint64(from value: Any?) -> UInt64? {
        switch value {
        case let n as UInt64:
            return n
        case let n as Int:
            return UInt64(bitPattern: Int64(n))
        case let n as NSNumber:
            return n.uint64Value
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("0x"),
               let v = UInt64(trimmed.dropFirst(2), radix: 16)
            {
                return v
            }
            return UInt64(trimmed)
        default:
            return nil
        }
    }

    // MARK: - Process helpers

    private func runHidutil(arguments: [String]) throws -> String {
        try runCheckedProcess(path: Self.hidutilPath, arguments: arguments)
    }

    @discardableResult
    private func runCheckedProcess(path: String, arguments: [String]) throws -> String {
        let result = try runProcess(path, arguments)
        guard result.terminationStatus == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw MicKeyManagerError.processFailed(
                path: path,
                status: result.terminationStatus,
                message: detail.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.stdout
    }

    nonisolated static func runProcessUnisolated(path: String, arguments: [String]) throws -> MicKeyProcessResult {
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
        return MicKeyProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

enum MicKeyManagerError: Error, LocalizedError {
    case processFailed(path: String, status: Int32, message: String)
    case persistenceUnhealthy(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let path, let status, let message):
            let suffix = message.isEmpty ? "" : ": \(message)"
            return "\(path) exited \(status)\(suffix)"
        case .persistenceUnhealthy(let reason):
            return reason
        }
    }
}
