import Foundation

/// Application configuration loaded from
/// `~/Library/Application Support/LocalDictation/config.json`.
struct AppConfig: Codable, Sendable {
    /// Absolute path to a server executable override. When set, resolution treats
    /// it as authoritative (no fallback on invalid/non-executable paths).
    var serverExecutable: String?

    /// WebSocket / health port (default 8471).
    var port: Int

    /// Optional HF model id override passed as `--model`.
    var model: String?

    static let defaultPort = 8471
    static let supportDirectoryName = "LocalDictation"
    static let configFileName = "config.json"

    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case invalidPort(Int)

        var description: String {
            switch self {
            case .invalidPort(let value):
                return "Invalid port \(value); expected an integer in 1...65535."
            }
        }
    }

    static var supportDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    static var configFileURL: URL {
        supportDirectoryURL.appendingPathComponent(configFileName)
    }

    init(serverExecutable: String? = nil, port: Int = defaultPort, model: String? = nil) {
        self.serverExecutable = serverExecutable
        self.port = port
        self.model = model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverExecutable = try container.decodeIfPresent(String.self, forKey: .serverExecutable)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
        model = try container.decodeIfPresent(String.self, forKey: .model)
    }

    /// Decodes JSON and validates port. Unlike `load()`, this surfaces invalid ports
    /// instead of silently falling back to defaults.
    static func decode(_ data: Data) throws -> AppConfig {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        try decoded.validate()
        return decoded
    }

    func validate() throws {
        guard (1...65535).contains(port) else {
            throw ValidationError.invalidPort(port)
        }
    }

    static func load() -> AppConfig {
        let url = configFileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return AppConfig()
        }
        do {
            let data = try Data(contentsOf: url)
            return try decode(data)
        } catch {
            AppLog.general.error(
                "Failed to load config at \(url.path, privacy: .public): \(String(describing: error), privacy: .public); using defaults"
            )
            return AppConfig()
        }
    }

    func save() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.supportDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.configFileURL, options: .atomic)
    }

    /// Production entry point: resolve a launch command using the running executable
    /// and Application Support directory.
    func resolveServerLaunchCommand(
        executableURL: URL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]),
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        supportDirectoryURL: URL = AppConfig.supportDirectoryURL
    ) -> Result<ServerLaunchCommand, ServerLaunchCommandResolver.ResolutionError> {
        let resolver = ServerLaunchCommandResolver(
            executableURL: executableURL,
            homeDirectoryURL: homeDirectoryURL,
            supportDirectoryURL: supportDirectoryURL
        )
        return resolver.resolve(override: serverExecutable)
    }

    var healthURL: URL {
        URL(string: "http://127.0.0.1:\(port)/health")!
    }

    var websocketURL: URL {
        URL(string: "ws://127.0.0.1:\(port)/v1/realtime")!
    }
}
