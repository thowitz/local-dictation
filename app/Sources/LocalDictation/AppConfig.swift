import Foundation

/// Application configuration loaded from
/// `~/Library/Application Support/LocalDictation/config.json`.
struct AppConfig: Codable, Sendable {
    /// Absolute path to a server executable override. When set, resolution treats
    /// it as authoritative (no fallback on invalid/non-executable paths).
    /// Only used when `provider == .voxtral`.
    var serverExecutable: String?

    /// WebSocket / health port (default 8471). Only used when `provider == .voxtral`.
    var port: Int

    /// Optional HF model id override passed as `--model` (Voxtral path only).
    var model: String?

    /// Speech backend. Defaults to `.voxtral` (Python MLX server).
    var provider: SpeechProvider

    /// Optional path to a staged Parakeet CoreML repo folder
    /// (e.g. `~/parakeet-tdt-0.6b-v3-coreml`). When set, FluidAudio loads offline
    /// from this directory instead of downloading. Only used for `.parakeet`.
    var parakeetModelPath: String?

    /// Minutes of inactivity before unloading the speech runtime.
    /// `0` disables unload; omitted/negative values resolve to `defaultIdleUnloadMinutes`.
    var idleUnloadMinutes: Double

    static let defaultPort = 8471
    static let defaultIdleUnloadMinutes: Double = 10
    static let defaultProvider: SpeechProvider = .voxtral
    static let supportDirectoryName = "LocalDictation"
    static let configFileName = "config.json"

    enum CodingKeys: String, CodingKey {
        case serverExecutable
        case port
        case model
        case provider
        case parakeetModelPath
        case idleUnloadMinutes
    }

    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case invalidPort(Int)
        case invalidProvider(String)

        var description: String {
            switch self {
            case .invalidPort(let value):
                return "Invalid port \(value); expected an integer in 1...65535."
            case .invalidProvider(let value):
                return "Invalid provider \(value); expected \"voxtral\" or \"parakeet\"."
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

    init(
        serverExecutable: String? = nil,
        port: Int = defaultPort,
        model: String? = nil,
        provider: SpeechProvider = defaultProvider,
        parakeetModelPath: String? = nil,
        idleUnloadMinutes: Double = defaultIdleUnloadMinutes
    ) {
        self.serverExecutable = serverExecutable
        self.port = port
        self.model = model
        self.provider = provider
        self.parakeetModelPath = parakeetModelPath
        self.idleUnloadMinutes = Self.normalizedIdleUnloadMinutes(idleUnloadMinutes)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverExecutable = try container.decodeIfPresent(String.self, forKey: .serverExecutable)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
        model = try container.decodeIfPresent(String.self, forKey: .model)
        if let rawProvider = try container.decodeIfPresent(String.self, forKey: .provider) {
            guard let parsed = SpeechProvider(rawValue: rawProvider.lowercased()) else {
                throw ValidationError.invalidProvider(rawProvider)
            }
            provider = parsed
        } else {
            provider = Self.defaultProvider
        }
        parakeetModelPath = try container.decodeIfPresent(String.self, forKey: .parakeetModelPath)
        let rawIdle = try container.decodeIfPresent(Double.self, forKey: .idleUnloadMinutes)
        idleUnloadMinutes = Self.normalizedIdleUnloadMinutes(rawIdle ?? Self.defaultIdleUnloadMinutes)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(serverExecutable, forKey: .serverExecutable)
        try container.encode(port, forKey: .port)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(provider.rawValue, forKey: .provider)
        try container.encodeIfPresent(parakeetModelPath, forKey: .parakeetModelPath)
        try container.encode(idleUnloadMinutes, forKey: .idleUnloadMinutes)
    }

    /// Effective idle timeout, or `nil` when unload is disabled (`idleUnloadMinutes == 0`).
    var idleUnloadTimeout: Duration? {
        guard idleUnloadMinutes > 0 else { return nil }
        return .seconds(idleUnloadMinutes * 60)
    }

    /// Normalize raw config: negative → default (with diagnostic), zero stays disabled.
    private static func normalizedIdleUnloadMinutes(_ raw: Double) -> Double {
        if raw < 0 {
            AppLog.general.error(
                "Invalid idleUnloadMinutes \(raw, privacy: .public); expected >= 0. Using default \(Self.defaultIdleUnloadMinutes, privacy: .public)."
            )
            return defaultIdleUnloadMinutes
        }
        return raw
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
