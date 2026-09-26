@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import os

/// In-process Parakeet **TDT 0.6B v3** engine (FluidAudio CoreML).
///
/// Live text comes from ``LocalAgreementStreamer``: every `stepSeconds` the
/// trailing buffer is batch-transcribed with full attention and words two
/// passes agree on are committed. Release runs one final pass with trailing
/// silence so the last words are not clipped.
actor ParakeetEngine {
    enum EngineError: Error, LocalizedError, Sendable {
        case notReady
        case modelNotFound(URL)
        case loadFailed(String)
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notReady:
                return "Parakeet TDT model is not loaded."
            case .modelNotFound(let url):
                return "Parakeet model not found at \(url.path)."
            case .loadFailed(let message):
                return "Parakeet model load failed: \(message)"
            case .transcriptionFailed(let message):
                return "Parakeet transcription failed: \(message)"
            }
        }
    }

    static let fluidAudioFolderName = "parakeet-tdt-0.6b-v3"
    static let huggingfaceRepoFolderName = "parakeet-tdt-0.6b-v3-coreml"

    private static let requiredBundleNames = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecisionv3.mlmodelc",
        "parakeet_vocab.json",
    ]

    /// Shared CoreML bundles (expensive).
    private var models: AsrModels?
    private var loadedFrom: URL?
    /// Batch transcriber used for every streaming pass.
    private var transcriber: AsrManager?

    private var streamer: LocalAgreementStreamer?
    private var stepSeconds = 0.5

    /// FluidAudio's "chunk" knob maps to the pass cadence; below ~0.4 s passes
    /// disagree too often to commit, above ~1.5 s text feels laggy.
    nonisolated static func passStepSeconds(chunkSeconds: Double) -> Double {
        min(1.5, max(0.4, chunkSeconds > 0 ? chunkSeconds : 0.5))
    }

    func isReady() async -> Bool {
        models != nil && transcriber != nil
    }

    func modelSourceDescription() -> String {
        if let loadedFrom { return loadedFrom.path }
        return models == nil ? "(not loaded)" : "(FluidAudio cache)"
    }

    func setChunkSeconds(_ seconds: Double) {
        stepSeconds = Self.passStepSeconds(chunkSeconds: seconds)
        AppLog.general.info(
            "Parakeet TDT pass step=\(self.stepSeconds, privacy: .public)s"
        )
    }

    // MARK: - Discovery

    nonisolated static func containsV3Bundles(at directory: URL) -> Bool {
        let fm = FileManager.default
        return requiredBundleNames.allSatisfy {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

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

    nonisolated static func makeLoadableDirectory(from directory: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return nil }
        if directory.lastPathComponent == fluidAudioFolderName, containsV3Bundles(at: directory) {
            return directory
        }
        if AsrModels.modelsExist(at: directory, version: .v3) {
            return directory
        }
        guard containsV3Bundles(at: directory) else { return nil }

        let stagingParent = AppConfig.supportDirectoryURL
            .appendingPathComponent("parakeet-models", isDirectory: true)
        let linkURL = stagingParent.appendingPathComponent(fluidAudioFolderName, isDirectory: true)
        do {
            try fm.createDirectory(at: stagingParent, withIntermediateDirectories: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: linkURL.path, isDirectory: &isDir) {
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
            return linkURL
        } catch {
            AppLog.general.error(
                "Parakeet failed to stage model directory: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - Load / unload

    func load(directory: URL?) async throws {
        if models != nil, transcriber != nil { return }
        do {
            let loaded: AsrModels
            if let directory {
                guard let loadable = Self.makeLoadableDirectory(from: directory)
                    ?? (Self.containsV3Bundles(at: directory) ? directory : nil)
                else { throw EngineError.modelNotFound(directory) }
                AppLog.general.info(
                    "Parakeet TDT loading from \(loadable.path, privacy: .public)"
                )
                ModelHub.offlineMode = true
                loaded = try await AsrModels.load(from: loadable, version: .v3)
                loadedFrom = loadable
            } else if let discovered = Self.resolveModelDirectory(explicitPath: nil) {
                AppLog.general.info(
                    "Parakeet TDT loading from \(discovered.path, privacy: .public)"
                )
                ModelHub.offlineMode = true
                loaded = try await AsrModels.load(from: discovered, version: .v3)
                loadedFrom = discovered
            } else {
                AppLog.general.info("Parakeet TDT downloading via FluidAudio")
                ModelHub.offlineMode = false
                loaded = try await AsrModels.downloadAndLoad(version: .v3)
                loadedFrom = AsrModels.defaultCacheDirectory(for: .v3)
            }
            models = loaded
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(loaded)
            transcriber = mgr
            AppLog.general.info(
                "Parakeet TDT ready source=\(self.modelSourceDescription(), privacy: .public) step=\(self.stepSeconds, privacy: .public)s"
            )
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.loadFailed(error.localizedDescription)
        }
    }

    func unload() async {
        streamer = nil
        if let transcriber {
            await transcriber.cleanup()
        }
        transcriber = nil
        models = nil
        loadedFrom = nil
        AppLog.general.info("Parakeet TDT unloaded")
    }

    // MARK: - Utterance

    func beginUtterance() async throws {
        guard models != nil, transcriber != nil else { throw EngineError.notReady }
        var config = LocalAgreementStreamer.Config()
        config.stepSeconds = stepSeconds
        streamer = LocalAgreementStreamer(config: config)
        AppLog.realtime.info("Parakeet TDT utterance start step=\(self.stepSeconds, privacy: .public)s")
    }

    /// Feed PCM16; returns a snapshot when a pass changed the visible text.
    @discardableResult
    func processAudio(pcm16: Data) async throws -> TranscriptSnapshot? {
        guard !pcm16.isEmpty else { return nil }
        if streamer == nil {
            try await beginUtterance()
        }
        guard streamer?.append(Self.pcm16ToFloat32(pcm16)) == true,
              let pass = streamer?.makePass(final: false)
        else { return nil }
        let words = try await transcribeWords(pass.samples)
        return streamer?.applyPass(pass, words: words)
    }

    /// Final pass over the unagreed tail; returns the utterance text.
    func finishUtterance() async throws -> String {
        guard var current = streamer else { return "" }
        streamer = nil
        guard current.hasAudio, !current.isSilentUtterance else { return "" }
        let pass = current.makePass(final: true)
        let started = Date()
        let words = try await transcribeWords(pass.samples)
        _ = current.applyPass(pass, words: words)
        let text = current.finalText()
        AppLog.realtime.info(
            "Parakeet TDT final pass \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms audio=\(current.duration, privacy: .public)s chars=\(text.count, privacy: .public)"
        )
        return text
    }

    func cancelUtterance() async {
        streamer = nil
    }

    // MARK: - Internals

    private func transcribeWords(_ samples: [Float]) async throws -> [TimedWord] {
        guard !samples.isEmpty else { return [] }
        guard let transcriber else { throw EngineError.notReady }
        var input = samples
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
        if input.count < minimum {
            input.append(contentsOf: repeatElement(0, count: minimum - input.count))
        }
        do {
            await transcriber.reset()
            let layers = await transcriber.decoderLayerCount
            var decoderState = TdtDecoderState.make(decoderLayers: layers)
            let result = try await transcriber.transcribe(input, decoderState: &decoderState)
            return Self.words(from: result.tokenTimings ?? [])
        } catch {
            throw EngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Group SentencePiece tokens (leading space = new word) into timed words.
    nonisolated static func words(from timings: [TokenTiming]) -> [TimedWord] {
        var words: [TimedWord] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        for timing in timings {
            let piece = timing.token
            if piece.hasPrefix(" ") || text.isEmpty {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    words.append(TimedWord(text: trimmed, start: start, end: end))
                }
                text = piece
                start = timing.startTime
            } else {
                text += piece
            }
            end = timing.endTime
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            words.append(TimedWord(text: trimmed, start: start, end: end))
        }
        return words
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
