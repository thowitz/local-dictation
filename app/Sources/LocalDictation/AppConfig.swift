import Foundation

/// Application configuration loaded from
/// `~/Library/Application Support/LocalDictation/config.json`.
struct AppConfig: Codable, Sendable {
    /// Absolute path to a server executable override. When set, resolution treats
    /// it as authoritative (no fallback on invalid/non-executable paths).
    /// Used for Python providers (`.voxtral`, `.parakeetMlx`).
    var serverExecutable: String?

    /// WebSocket / health port (default 8471). Used for Python providers.
    var port: Int

    /// Optional HF model id override passed as `--model`.
    var model: String?

    /// Speech backend. Defaults to `.voxtral` (Python MLX Voxtral server).
    var provider: SpeechProvider

    /// Optional path to a staged Parakeet TDT v3 CoreML repo folder
    /// (e.g. `~/parakeet-tdt-0.6b-v3-coreml`). Only used for `.parakeet`.
    var parakeetModelPath: String?

    /// Optional path to a staged Parakeet TDT MLX repo folder
    /// (e.g. `~/parakeet-tdt-0.6b-v3`). Passed as `--model` for `.parakeetMlx`
    /// so loads skip Hugging Face. Falls back to `model` / default HF id.
    var parakeetMlxModelPath: String?

    /// Sliding-window center stride (CoreML) / stream step (MLX) in seconds.
    /// Default `0.75`. Smaller → more frequent partials (noisier). CoreML maps
    /// this to FluidAudio `SlidingWindowAsrConfig.chunkSeconds` (clamped).
    var parakeetChunkSeconds: Double

    /// Minutes of inactivity before unloading the speech runtime.
    /// `0` disables unload; omitted/negative values resolve to `defaultIdleUnloadMinutes`.
    var idleUnloadMinutes: Double

    static let defaultPort = 8471
    static let defaultIdleUnloadMinutes: Double = 10
    /// Default sliding-window / MLX stream stride for live partials.
    /// CoreML TDT needs ≥ ~1 s centers for stable windows; 1.5 s is a good default.
    static let defaultParakeetChunkSeconds: Double = 1.5
    static let defaultProvider: SpeechProvider = .voxtral
    static let supportDirectoryName = "LocalDictation"
    static let configFileName = "config.json"

    enum CodingKeys: String, CodingKey {
        case serverExecutable
        case port
        case model
        case provider
        case parakeetModelPath
        case parakeetMlxModelPath
        case parakeetChunkSeconds
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
                return "Invalid provider \(value); expected \"voxtral\", \"parakeet\", or \"parakeet-mlx\"."
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
        parakeetMlxModelPath: String? = nil,
        parakeetChunkSeconds: Double = defaultParakeetChunkSeconds,
        idleUnloadMinutes: Double = defaultIdleUnloadMinutes
    ) {
        self.serverExecutable = serverExecutable
        self.port = port
        self.model = model
        self.provider = provider
        self.parakeetModelPath = parakeetModelPath
        self.parakeetMlxModelPath = parakeetMlxModelPath
        self.parakeetChunkSeconds = Self.normalizedChunkSeconds(parakeetChunkSeconds)
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
        parakeetMlxModelPath = try container.decodeIfPresent(String.self, forKey: .parakeetMlxModelPath)
        let rawChunk = try container.decodeIfPresent(Double.self, forKey: .parakeetChunkSeconds)
        parakeetChunkSeconds = Self.normalizedChunkSeconds(
            rawChunk ?? Self.defaultParakeetChunkSeconds
        )
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
        try container.encodeIfPresent(parakeetMlxModelPath, forKey: .parakeetMlxModelPath)
        try container.encode(parakeetChunkSeconds, forKey: .parakeetChunkSeconds)
        try container.encode(idleUnloadMinutes, forKey: .idleUnloadMinutes)
    }

    /// Effective idle timeout, or `nil` when unload is disabled (`idleUnloadMinutes == 0`).
    var idleUnloadTimeout: Duration? {
        guard idleUnloadMinutes > 0 else { return nil }
        return .seconds(idleUnloadMinutes * 60)
    }

    /// `--backend` value for the Python server, or nil when not applicable.
    var serverBackendFlag: String? {
        switch provider {
        case .voxtral: return "voxtral"
        case .parakeetMlx: return "parakeet-mlx"
        case .parakeet: return nil
        }
    }

    /// Model id or local path passed as `--model` for the Python server.
    var resolvedServerModel: String? {
        switch provider {
        case .voxtral:
            return model
        case .parakeetMlx:
            if let path = parakeetMlxModelPath, !path.isEmpty {
                return (path as NSString).expandingTildeInPath
            }
            if let model, !model.isEmpty { return model }
            // Auto-discover a staged clone under ~ if present.
            if let discovered = Self.discoverParakeetMlxModelDirectory() {
                return discovered.path
            }
            return SpeechProvider.parakeetMlxDefaultModel
        case .parakeet:
            return nil
        }
    }

    /// Lightweight check that `directory` looks like a parakeet-mlx / HF weight tree
    /// (config + tokenizer; weight files may still be Git-LFS pending).
    static func looksLikeParakeetMlxModelDirectory(_ directory: URL) -> Bool {
        let fm = FileManager.default
        let config = directory.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: config.path) else { return false }
        // Reject CoreML trees so users don't pick the wrong clone.
        let coreMLMarkers = ["Encoder.mlmodelc", "Preprocessor.mlmodelc", "JointDecisionv3.mlmodelc"]
        if coreMLMarkers.contains(where: {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) {
            return false
        }
        let tokenizerHints = [
            "tokenizer.model",
            "tokenizer.vocab",
            "vocab.txt",
            "tokenizer.json",
        ]
        let hasTokenizer = tokenizerHints.contains {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        return hasTokenizer
    }

    /// Prefer `~/parakeet-tdt-0.6b-v3` (HF mlx-community clone name without `-coreml`).
    static func discoverParakeetMlxModelDirectory() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true),
            home.appendingPathComponent("mlx-community/parakeet-tdt-0.6b-v3", isDirectory: true),
        ]
        for url in candidates where looksLikeParakeetMlxModelDirectory(url) {
            return url
        }
        return nil
    }

    private static func normalizedIdleUnloadMinutes(_ raw: Double) -> Double {
        if raw < 0 {
            AppLog.general.error(
                "Invalid idleUnloadMinutes \(raw, privacy: .public); expected >= 0. Using default \(Self.defaultIdleUnloadMinutes, privacy: .public)."
            )
            return defaultIdleUnloadMinutes
        }
        return raw
    }

    private static func normalizedChunkSeconds(_ raw: Double) -> Double {
        if raw < 0 {
            AppLog.general.error(
                "Invalid parakeetChunkSeconds \(raw, privacy: .public); expected >= 0. Using default \(Self.defaultParakeetChunkSeconds, privacy: .public)."
            )
            return defaultParakeetChunkSeconds
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
