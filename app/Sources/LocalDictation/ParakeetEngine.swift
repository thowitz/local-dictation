@preconcurrency import CoreML
import FluidAudio
import Foundation
import os

/// Shared in-process Parakeet TDT engine used by the runtime (load/unload) and
/// the realtime client (buffer + batch transcribe on finalize).
actor ParakeetEngine {
    enum EngineError: Error, LocalizedError, Sendable {
        case notReady
        case modelNotFound(URL)
        case loadFailed(String)
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notReady:
                return "Parakeet model is not loaded."
            case .modelNotFound(let url):
                return "Parakeet model not found at \(url.path)."
            case .loadFailed(let message):
                return "Parakeet model load failed: \(message)"
            case .transcriptionFailed(let message):
                return "Parakeet transcription failed: \(message)"
            }
        }
    }

    /// FluidAudio's on-disk cache folder for v3 (strips the HF `-coreml` suffix).
    /// `AsrModels.load(from:)` resolves models via `parent/folderName/…`.
    static let fluidAudioFolderName = "parakeet-tdt-0.6b-v3"

    /// Common staged directory names users may already have (HF clone name).
    static let huggingfaceRepoFolderName = "parakeet-tdt-0.6b-v3-coreml"

    private static let requiredBundleNames = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecisionv3.mlmodelc",
        "parakeet_vocab.json",
    ]

    private var asrManager: AsrManager?
    private var loadedFrom: URL?

    func isReady() async -> Bool {
        guard let asrManager else { return false }
        return await asrManager.isAvailable
    }

    func modelSourceDescription() -> String {
        if let loadedFrom {
            return loadedFrom.path
        }
        return "(not loaded)"
    }

    /// True when `directory` itself contains the v3 CoreML bundles + vocab.
    nonisolated static func containsV3Bundles(at directory: URL) -> Bool {
        let fm = FileManager.default
        return requiredBundleNames.allSatisfy { name in
            fm.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    /// Resolve a staged model directory for `AsrModels.load(from:)`.
    ///
    /// FluidAudio expects the last path component to be its cache folder name
    /// (`parakeet-tdt-0.6b-v3`). Hugging Face clones commonly use
    /// `parakeet-tdt-0.6b-v3-coreml`. When the user points at a HF-layout folder,
    /// we create a stable symlink under Application Support so load works offline.
    nonisolated static func resolveModelDirectory(explicitPath: String?) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let explicitPath, !explicitPath.isEmpty {
            let expanded = (explicitPath as NSString).expandingTildeInPath
            candidates.append(URL(fileURLWithPath: expanded, isDirectory: true))
        }

        let home = fm.homeDirectoryForCurrentUser
        candidates.append(contentsOf: [
            home.appendingPathComponent(huggingfaceRepoFolderName, isDirectory: true),
            home.appendingPathComponent(fluidAudioFolderName, isDirectory: true),
            home
                .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
                .appendingPathComponent(fluidAudioFolderName, isDirectory: true),
            home
                .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
                .appendingPathComponent(huggingfaceRepoFolderName, isDirectory: true),
            AppConfig.supportDirectoryURL
                .appendingPathComponent("parakeet-models", isDirectory: true)
                .appendingPathComponent(fluidAudioFolderName, isDirectory: true),
        ])

        for candidate in candidates {
            if let loadable = makeLoadableDirectory(from: candidate) {
                return loadable
            }
        }
        return nil
    }

    /// Returns a directory suitable for `AsrModels.load(from:)` or nil.
    nonisolated static func makeLoadableDirectory(from directory: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return nil }

        // Already in FluidAudio's expected layout (parent/folderName).
        if directory.lastPathComponent == fluidAudioFolderName, containsV3Bundles(at: directory) {
            return directory
        }
        if AsrModels.modelsExist(at: directory, version: .v3) {
            return directory
        }

        // HF clone / arbitrary folder that directly holds the bundles.
        guard containsV3Bundles(at: directory) else { return nil }

        // Stage a stable symlink: Application Support/LocalDictation/parakeet-models/parakeet-tdt-0.6b-v3 → directory
        let stagingParent = AppConfig.supportDirectoryURL
            .appendingPathComponent("parakeet-models", isDirectory: true)
        let linkURL = stagingParent.appendingPathComponent(fluidAudioFolderName, isDirectory: true)

        do {
            try fm.createDirectory(at: stagingParent, withIntermediateDirectories: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: linkURL.path, isDirectory: &isDir) {
                // Re-point if it's a symlink or wrong target.
                let attrs = try? fm.attributesOfItem(atPath: linkURL.path)
                let isSymlink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
                if isSymlink {
                    let dest = try? fm.destinationOfSymbolicLink(atPath: linkURL.path)
                    if dest == directory.path || dest == directory.resolvingSymlinksInPath().path {
                        return linkURL
                    }
                    try fm.removeItem(at: linkURL)
                } else if containsV3Bundles(at: linkURL) {
                    return linkURL
                } else {
                    try fm.removeItem(at: linkURL)
                }
            }
            try fm.createSymbolicLink(at: linkURL, withDestinationURL: directory)
            AppLog.general.info(
                "Parakeet staged model symlink \(linkURL.path, privacy: .public) → \(directory.path, privacy: .public)"
            )
            return linkURL
        } catch {
            AppLog.general.error(
                "Parakeet failed to stage model directory: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Load models. When `directory` is set, loads offline from that folder.
    /// Otherwise uses FluidAudio download-and-load (Hugging Face cache).
    func load(directory: URL?) async throws {
        if await isReady() { return }

        do {
            let models: AsrModels
            if let directory {
                guard let loadable = Self.makeLoadableDirectory(from: directory)
                    ?? (Self.containsV3Bundles(at: directory) ? directory : nil)
                else {
                    throw EngineError.modelNotFound(directory)
                }
                AppLog.general.info(
                    "Parakeet loading CoreML models from \(loadable.path, privacy: .public)"
                )
                // Prefer offline when a staged directory is provided.
                ModelHub.offlineMode = true
                models = try await AsrModels.load(from: loadable, version: .v3)
                loadedFrom = loadable
            } else {
                AppLog.general.info("Parakeet downloading/loading CoreML models via FluidAudio")
                ModelHub.offlineMode = false
                models = try await AsrModels.downloadAndLoad(version: .v3)
                loadedFrom = AsrModels.defaultCacheDirectory(for: .v3)
            }

            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asrManager = manager
            let source = modelSourceDescription()
            AppLog.general.info("Parakeet models ready (source=\(source, privacy: .public))")
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.loadFailed(error.localizedDescription)
        }
    }

    func unload() async {
        if let asrManager {
            await asrManager.cleanup()
        }
        asrManager = nil
        loadedFrom = nil
        AppLog.general.info("Parakeet models unloaded")
    }

    /// Transcribe 16 kHz mono PCM16 little-endian audio.
    func transcribe(pcm16: Data) async throws -> String {
        guard let asrManager, await asrManager.isAvailable else {
            throw EngineError.notReady
        }

        let samples = Self.pcm16ToFloat32(pcm16)
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
        guard samples.count >= minimum else {
            // Too short to recognize — treat as empty utterance rather than failing the session.
            return ""
        }

        do {
            let layers = await asrManager.decoderLayerCount
            var decoderState = TdtDecoderState.make(decoderLayers: layers)
            let result = try await asrManager.transcribe(samples, decoderState: &decoderState)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw EngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    nonisolated static func pcm16ToFloat32(_ data: Data) -> [Float] {
        guard !data.isEmpty else { return [] }
        let sampleCount = data.count / MemoryLayout<Int16>.size
        return data.withUnsafeBytes { raw -> [Float] in
            let buffer = raw.bindMemory(to: Int16.self)
            var samples = [Float](repeating: 0, count: sampleCount)
            let scale = Float(Int16.max)
            for i in 0..<sampleCount {
                samples[i] = Float(buffer[i]) / scale
            }
            return samples
        }
    }
}
