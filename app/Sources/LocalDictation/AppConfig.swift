import Foundation
import os

/// Application configuration loaded from
/// `~/Library/Application Support/LocalDictation/config.json`.
struct AppConfig: Codable, Sendable {
    /// Absolute path to `local-dictation-serve`. When nil, the compiled-in
    /// repo-relative default is used.
    var serverExecutable: String?

    /// WebSocket / health port (default 8471).
    var port: Int

    /// Optional HF model id override passed as `--model`.
    var model: String?

    static let defaultPort = 8471
    static let supportDirectoryName = "LocalDictation"
    static let configFileName = "config.json"

    /// Compiled-in fallback: `<repo>/server/.venv/bin/local-dictation-serve`
    /// where `<repo>` is two levels above the executable when running from
    /// `.build/.../debug/LocalDictation`, or the hard-coded workspace path.
    static let compiledInRepoRoot = "/Users/oxxxx/Code/local-dictation"

    static var supportDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    static var configFileURL: URL {
        supportDirectoryURL.appendingPathComponent(configFileName)
    }

    static func load() -> AppConfig {
        let url = configFileURL
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data)
        {
            return decoded
        }
        return AppConfig(serverExecutable: nil, port: defaultPort, model: nil)
    }

    func save() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.supportDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.configFileURL, options: .atomic)
    }

    /// Resolved absolute path to the server executable.
    var resolvedServerExecutable: URL {
        if let override = serverExecutable, !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: Self.compiledInRepoRoot)
            .appendingPathComponent("server/.venv/bin/local-dictation-serve")
    }

    var healthURL: URL {
        URL(string: "http://127.0.0.1:\(port)/health")!
    }

    var websocketURL: URL {
        URL(string: "ws://127.0.0.1:\(port)/v1/realtime")!
    }
}

enum AppLog {
    static let general = Logger(subsystem: "com.local-dictation", category: "app")
    static let server = Logger(subsystem: "com.local-dictation", category: "server")
    static let realtime = Logger(subsystem: "com.local-dictation", category: "realtime")
    static let audio = Logger(subsystem: "com.local-dictation", category: "audio")
}
