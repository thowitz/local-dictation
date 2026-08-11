@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import os

/// In-process Parakeet **TDT 0.6B v3** engine.
///
/// Live partials use FluidAudio `SlidingWindowAsrManager` with a **short dictation
/// window** (not the long-form ~11 s default). Release runs a full-buffer
/// `AsrManager.transcribe` with trailing silence so the last words are not clipped.
///
/// Window math: first partial after roughly `chunk + right` seconds of audio.
/// `parakeetChunkSeconds` maps to the center stride (clamped for quality).
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
    /// Dedicated finalizer for full-buffer commit (silence-padded).
    private var finalizer: AsrManager?

    private var stream: SlidingWindowAsrManager?
    private var updateTask: Task<Void, Never>?
    private var partialHandler: (@Sendable (String) -> Void)?
    /// PCM16 for the active hold — used for high-quality final re-transcribe.
    private var utterancePCM = Data()
    /// Longest non-empty partial seen this hold (sliding window can briefly blank).
    private var bestPartial = ""

    private var windowConfig: SlidingWindowAsrConfig =
        ParakeetEngine.dictationWindowConfig(chunkSeconds: 1.5)

    /// Dictation-tuned window. TDT degrades badly below ~1 s centers; FluidAudio
    /// long-form uses ~11 s. We sit in the middle for live partials + quality.
    nonisolated static func dictationWindowConfig(chunkSeconds: Double) -> SlidingWindowAsrConfig {
        // Floor 1.0s: shorter centers produce empty follow-up windows on TDT v3.
        let chunk = min(4.0, max(1.0, chunkSeconds > 0 ? chunkSeconds : 1.5))
        let right = min(0.75, max(0.35, chunk * 0.3))
        let left = min(3.0, max(1.5, chunk))
        // Confirm earlier than long-form's 10 s so inserts stick during a hold.
        let minConfirm = min(4.0, max(1.5, chunk + right))
        return SlidingWindowAsrConfig(
            chunkSeconds: chunk,
            hypothesisChunkSeconds: min(1.0, chunk * 0.5),
            leftContextSeconds: left,
            rightContextSeconds: right,
            minContextForConfirmation: minConfirm,
            confirmationThreshold: 0.70
        )
    }

    func isReady() async -> Bool {
        models != nil && finalizer != nil
    }

    func modelSourceDescription() -> String {
        if let loadedFrom { return loadedFrom.path }
        return models == nil ? "(not loaded)" : "(FluidAudio cache)"
    }

    func setPartialHandler(_ handler: (@Sendable (String) -> Void)?) {
        partialHandler = handler
    }

    func setChunkSeconds(_ seconds: Double) {
        windowConfig = Self.dictationWindowConfig(chunkSeconds: seconds)
        AppLog.general.info(
            "Parakeet TDT window chunk=\(self.windowConfig.chunkSeconds, privacy: .public)s left=\(self.windowConfig.leftContextSeconds, privacy: .public)s right=\(self.windowConfig.rightContextSeconds, privacy: .public)s (first partial ~\(self.windowConfig.chunkSeconds + self.windowConfig.rightContextSeconds, privacy: .public)s)"
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
        if models != nil, finalizer != nil { return }
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
            finalizer = mgr
            AppLog.general.info(
                "Parakeet TDT ready source=\(self.modelSourceDescription(), privacy: .public) chunk=\(self.windowConfig.chunkSeconds, privacy: .public)s"
            )
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.loadFailed(error.localizedDescription)
        }
    }

    func unload() async {
        await endStream(cancelOnly: true)
        if let finalizer {
            await finalizer.cleanup()
        }
        finalizer = nil
        models = nil
        loadedFrom = nil
        AppLog.general.info("Parakeet TDT unloaded")
    }

    // MARK: - Utterance

    func beginUtterance() async throws {
        guard let models else { throw EngineError.notReady }
        await endStream(cancelOnly: true)
        utterancePCM.removeAll(keepingCapacity: true)
        bestPartial = ""

        let manager = SlidingWindowAsrManager(config: windowConfig)
        try await manager.loadModels(models)
        let updates = await manager.transcriptionUpdates
        updateTask = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                await self.handleStreamUpdate(update)
            }
        }
        try await manager.startStreaming(source: .microphone)
        stream = manager
        AppLog.realtime.info(
            "Parakeet TDT stream start chunk=\(self.windowConfig.chunkSeconds, privacy: .public)s"
        )
    }

    func processAudio(pcm16: Data) async throws {
        guard !pcm16.isEmpty else { return }
        if stream == nil {
            try await beginUtterance()
        }
        utterancePCM.append(pcm16)
        guard let stream, let buffer = Self.makeFloatPCMBuffer(fromPCM16: pcm16) else {
            throw EngineError.transcriptionFailed("Failed to build audio buffer")
        }
        await stream.streamAudio(buffer)
    }

    func finishUtterance() async throws -> String {
        // Stop sliding-window stream (may leave a partial transcript).
        let streamText: String
        if let stream {
            do {
                streamText = try await stream.finish()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                streamText = bestPartial
                AppLog.realtime.error(
                    "Parakeet TDT stream finish error: \(error.localizedDescription, privacy: .public)"
                )
            }
        } else {
            streamText = bestPartial
        }
        await endStream(cancelOnly: false)

        // Full-buffer finalize with trailing silence — TDT needs this for last words
        // and recovers content that short windows missed.
        let pcm = utterancePCM
        utterancePCM.removeAll(keepingCapacity: true)
        bestPartial = ""

        guard !pcm.isEmpty else { return streamText }
        do {
            let finalText = try await transcribeFullBuffer(pcm16: pcm)
            if finalText.isEmpty {
                return streamText
            }
            // Prefer the longer / more complete result.
            if finalText.count >= streamText.count || streamText.isEmpty {
                return finalText
            }
            return streamText
        } catch {
            if !streamText.isEmpty { return streamText }
            throw error
        }
    }

    func cancelUtterance() async {
        await endStream(cancelOnly: true)
        utterancePCM.removeAll(keepingCapacity: false)
        bestPartial = ""
    }

    func currentPartial() async -> String { bestPartial }

    // MARK: - Internals

    private func handleStreamUpdate(_ update: SlidingWindowTranscriptionUpdate) async {
        guard let stream else { return }
        let composed = Self.composeTranscript(
            confirmed: await stream.confirmedTranscript,
            volatile: await stream.volatileTranscript
        )
        // Sliding-window can emit empty follow-up windows that wipe volatile.
        // Keep the best non-empty growing text for partials.
        let candidate: String
        if composed.isEmpty {
            candidate = bestPartial
        } else if bestPartial.isEmpty
            || composed.hasPrefix(bestPartial)
            || composed.count >= bestPartial.count
        {
            candidate = composed
        } else {
            candidate = bestPartial
        }
        guard !candidate.isEmpty, candidate != bestPartial || update.isConfirmed else {
            if !candidate.isEmpty { bestPartial = candidate }
            return
        }
        bestPartial = candidate
        partialHandler?(candidate)
        AppLog.realtime.info(
            "Parakeet TDT partial conf=\(update.confidence, privacy: .public) confirmed=\(update.isConfirmed, privacy: .public) chars=\(candidate.count, privacy: .public)"
        )
    }

    private func endStream(cancelOnly: Bool) async {
        updateTask?.cancel()
        updateTask = nil
        if let stream, cancelOnly {
            await stream.cancel()
        }
        stream = nil
    }

    /// Batch-transcribe the full hold with ~500 ms trailing silence.
    private func transcribeFullBuffer(pcm16: Data) async throws -> String {
        guard let finalizer else { throw EngineError.notReady }
        let padded = Self.appendSilence(to: pcm16, seconds: 0.5)
        let samples = Self.pcm16ToFloat32(padded)
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
        guard samples.count >= minimum else { return "" }
        do {
            await finalizer.reset()
            let layers = await finalizer.decoderLayerCount
            var decoderState = TdtDecoderState.make(decoderLayers: layers)
            let result = try await finalizer.transcribe(samples, decoderState: &decoderState)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw EngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    nonisolated static func composeTranscript(confirmed: String, volatile: String) -> String {
        let c = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.isEmpty { return v }
        if v.isEmpty { return c }
        if v.hasPrefix(c) { return v }
        return c + " " + v
    }

    nonisolated static func appendSilence(to pcm16: Data, seconds: Double) -> Data {
        guard seconds > 0, !pcm16.isEmpty else { return pcm16 }
        let n = Int(seconds * 16_000)
        guard n > 0 else { return pcm16 }
        var out = pcm16
        out.append(Data(count: n * MemoryLayout<Int16>.size))
        return out
    }

    nonisolated static func makeFloatPCMBuffer(fromPCM16 data: Data) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            let scale = Float(Int16.max)
            for i in 0..<sampleCount {
                channel[i] = Float(src[i]) / scale
            }
        }
        return buffer
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
