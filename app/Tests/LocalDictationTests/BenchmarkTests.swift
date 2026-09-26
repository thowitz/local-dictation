@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Speech
import Testing
@testable import LocalDictation

/// Opt-in ASR benchmark harness (see `LD_BENCH_DIR/prep.py`). Writes
/// `results/<engine>.json` in the same shape as the Python runner, so one
/// scorer covers every engine. Nothing runs unless `LD_BENCH_DIR` is set.
///
///     LD_BENCH_DIR=… LD_BENCH_COREML="coreml-v3=/dir:v3;coreml-v2=/dir:v2" \
///       swift test --filter BenchmarkTests.coreML
///     LD_BENCH_DIR=… swift test --filter BenchmarkTests.apple
///     LD_BENCH_DIR=… swift test --filter BenchmarkTests.replayTypist
@Suite("Benchmark", .serialized)
struct BenchmarkTests {
    private static let env = ProcessInfo.processInfo.environment
    private static var root: URL? { env["LD_BENCH_DIR"].map { URL(fileURLWithPath: $0) } }
    /// Alternative manifests (e.g. noisy sets); `LD_BENCH_STREAM=none` skips streaming.
    private static var batchManifest: String { env["LD_BENCH_BATCH"] ?? "batch.json" }
    private static var streamManifest: String { env["LD_BENCH_STREAM"] ?? "stream.json" }
    private static var suffix: String { env["LD_BENCH_SUFFIX"] ?? "" }

    struct Item: Codable {
        var id: String
        var wav: String
        var ref: String
        var seconds: Double
    }

    // MARK: - CoreML (FluidAudio)

    @Test("CoreML Parakeet variants: batch + LocalAgreement streaming")
    func coreML() async throws {
        guard let root = Self.root, let spec = Self.env["LD_BENCH_COREML"] else { return }
        ModelHub.offlineMode = true
        for entry in spec.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            let pathAndVersion = parts[1].split(separator: ":").map(String.init)
            let name = parts[0] + Self.suffix
            let version: AsrModelVersion = pathAndVersion[1] == "v2" ? .v2 : .v3
            let modelDir = URL(fileURLWithPath: pathAndVersion[0])

            // FluidAudio loads from <parent>/<fixed repo folder>; stage a symlink.
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent("ld-bench-\(name)")
            try? FileManager.default.removeItem(at: stage)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let folders = version == .v2
                ? ["parakeet-tdt-0.6b-v2-coreml", "parakeet-tdt-0.6b-v2"]
                : ["parakeet-tdt-0.6b-v3-coreml", "parakeet-tdt-0.6b-v3"]
            for folder in folders {
                try FileManager.default.createSymbolicLink(
                    at: stage.appendingPathComponent(folder), withDestinationURL: modelDir)
            }

            let started = Date()
            let models = try await AsrModels.load(from: stage.appendingPathComponent(folders[0]), version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let loadSeconds = Date().timeIntervalSince(started)
            print("BENCH \(name) loaded in \(String(format: "%.1f", loadSeconds))s")

            func transcribe(_ samples: [Float]) async throws -> [TimedWord] {
                var input = samples
                let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
                if input.count < minimum { input += [Float](repeating: 0, count: minimum - input.count) }
                await manager.reset()
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let result = try await manager.transcribe(input, decoderState: &state)
                return ParakeetEngine.words(from: result.tokenTimings ?? [])
            }
            for _ in 0..<3 { _ = try await transcribe([Float](repeating: 0.01, count: 48_000)) }

            var result = Self.newResult(engine: name, kind: "coreml", model: modelDir.path, loadSeconds: loadSeconds)
            try await Self.runBatch(root: root, into: &result) { try await transcribe($0) }
            if Self.streamManifest != "none" {
                try await Self.runStream(root: root, into: &result, name: name) { try await transcribe($0) }
            }
            try Self.write(result, root: root, name: name)
            await manager.cleanup()
        }
    }

    // MARK: - Apple on-device speech

    @Test("Apple SpeechTranscriber / DictationTranscriber: batch + volatile probe")
    func apple() async throws {
        guard let root = Self.root, Self.env["LD_BENCH_APPLE"] != nil else { return }
        guard #available(macOS 26, *) else { return }
        try await Self.runApple(root: root)
    }

    struct AppleEvent: Sendable {
        var text: String
        var start: Double
        var end: Double
        var final: Bool
        var wall: Double = 0

        var json: [String: Any] {
            ["text": text, "start": start, "end": end, "final": final, "wall": wall]
        }
    }

    @available(macOS 26, *)
    private static func runApple(root: URL) async throws {
        let locale = Locale(identifier: "en-US")
        let kinds = env["LD_BENCH_APPLE_KINDS"].map { $0.split(separator: ",").map(String.init) }
            ?? ["apple-speech", "apple-dictation"]
        for baseKind in kinds {
            let kind = baseKind
            let batchModule = Self.makeModule(kind, locale: locale, volatile: false)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [batchModule]) {
                print("BENCH \(kind) installing assets…")
                try await request.downloadAndInstall()
            }
            var result = Self.newResult(engine: kind + suffix, kind: "apple", model: kind, loadSeconds: 0)

            let items = try Self.items(root, batchManifest)
            var batch: [[String: Any]] = []
            for item in items {
                let module = Self.makeModule(kind, locale: locale, volatile: false)
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: item.wav))
                let started = Date()
                let text = try await Self.transcribeFile(file, module: module)
                batch.append(["id": item.id, "hyp": text, "audio_s": item.seconds, "ms": Date().timeIntervalSince(started) * 1000])
            }
            result["batch"] = batch
            print("BENCH \(kind) batch done")

            // Volatile probe: stream at 2× real time; log every result with its range.
            var stream: [[String: Any]] = []
            for item in streamManifest == "none" ? [] : try Self.items(root, streamManifest) {
                let module = Self.makeModule(kind, locale: locale, volatile: true)
                let events = try await Self.streamProbe(URL(fileURLWithPath: item.wav), module: module)
                let finals = events.filter(\.final).sorted { $0.start < $1.start }.map(\.text)
                stream.append(["id": item.id, "audio_s": item.seconds, "apple_events": events.map(\.json),
                               "final": finals.joined(separator: " ").replacingOccurrences(of: "  ", with: " ")])
            }
            result["stream"] = stream
            try Self.write(result, root: root, name: kind + suffix)
        }
    }

    @available(macOS 26, *)
    private static func makeModule(_ kind: String, locale: Locale, volatile: Bool) -> any SpeechModule {
        if kind == "apple-speech" {
            return SpeechTranscriber(
                locale: locale, transcriptionOptions: [],
                reportingOptions: volatile ? [.volatileResults] : [], attributeOptions: [.audioTimeRange])
        }
        return DictationTranscriber(
            locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
            reportingOptions: volatile ? [.volatileResults] : [], attributeOptions: [.audioTimeRange])
    }

    @available(macOS 26, *)
    private static func results(of module: any SpeechModule) -> AsyncThrowingStream<AppleEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let t = module as? SpeechTranscriber {
                        for try await r in t.results {
                            continuation.yield(AppleEvent(text: String(r.text.characters), start: r.range.start.seconds, end: r.range.end.seconds, final: r.isFinal))
                        }
                    } else if let t = module as? DictationTranscriber {
                        for try await r in t.results {
                            continuation.yield(AppleEvent(text: String(r.text.characters), start: r.range.start.seconds, end: r.range.end.seconds, final: r.isFinal))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @available(macOS 26, *)
    private static func transcribeFile(_ file: AVAudioFile, module: any SpeechModule) async throws -> String {
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { () -> [String] in
            var out: [String] = []
            for try await r in results(of: module) where r.final { out.append(r.text) }
            return out
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await collector.value.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    @available(macOS 26, *)
    private static func streamProbe(_ url: URL, module: any SpeechModule) async throws -> [AppleEvent] {
        let file = try AVAudioFile(forReading: url)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw NSError(domain: "bench", code: 1) }
        try file.read(into: source)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(source.frameLength) * format.sampleRate / file.processingFormat.sampleRate) + 1024)
        else { throw NSError(domain: "bench", code: 2) }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return source
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        let (input, builder) = AsyncStream<AnalyzerInput>.makeStream()
        let started = Date()
        let collector = Task { () -> [AppleEvent] in
            var events: [AppleEvent] = []
            for try await r in results(of: module) {
                var event = r
                event.wall = Date().timeIntervalSince(started)
                events.append(event)
            }
            return events
        }
        try await analyzer.start(inputSequence: input)
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        var offset: AVAudioFrameCount = 0
        while offset < converted.frameLength {
            let n = min(chunk, converted.frameLength - offset)
            let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
            piece.frameLength = n
            for ch in 0..<Int(format.channelCount) {
                if let src = converted.floatChannelData?[ch], let dst = piece.floatChannelData?[ch] {
                    dst.update(from: src.advanced(by: Int(offset)), count: Int(n))
                } else if let src = converted.int16ChannelData?[ch], let dst = piece.int16ChannelData?[ch] {
                    dst.update(from: src.advanced(by: Int(offset)), count: Int(n))
                }
            }
            builder.yield(AnalyzerInput(buffer: piece))
            offset += n
            try await Task.sleep(for: .milliseconds(50))
        }
        builder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    // MARK: - Typist replay (all engines)

    @Test("Replay every engine's streaming snapshots through DictationTypist")
    func replayTypist() throws {
        guard let root = Self.root, Self.env["LD_BENCH_REPLAY"] != nil else { return }
        let dir = root.appendingPathComponent("results")
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        where file.pathExtension == "json" && !file.lastPathComponent.contains(".typed.") {
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            guard var stream = json["stream"] as? [[String: Any]] else { continue }
            for i in stream.indices {
                guard let snapshots = stream[i]["snapshots"] as? [[String]] else { continue }
                var typist = DictationTypist()
                var screen = ScreenModel()
                var maxDelete = 0
                var totalDelete = 0
                for s in snapshots {
                    let edit = typist.apply(committed: s[0], draft: s[1])
                    maxDelete = max(maxDelete, edit.deleteCount)
                    totalDelete += edit.deleteCount
                    screen.apply(edit)
                }
                let final = typist.finish(finalText: stream[i]["final"] as? String ?? "")
                maxDelete = max(maxDelete, final.deleteCount)
                totalDelete += final.deleteCount
                screen.apply(final)
                stream[i]["typed"] = screen.text
                stream[i]["max_del"] = maxDelete
                stream[i]["total_del"] = totalDelete
                stream[i]["final_del"] = final.deleteCount
                stream[i]["realigns"] = typist.realignCount
                stream[i].removeValue(forKey: "snapshots")
            }
            json["stream"] = stream
            let out = dir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".typed.json")
            try JSONSerialization.data(withJSONObject: json).write(to: out)
            print("BENCH replayed \(file.lastPathComponent)")
        }
    }

    // MARK: - Shared

    private static func items(_ root: URL, _ name: String) throws -> [Item] {
        try JSONDecoder().decode([Item].self, from: Data(contentsOf: root.appendingPathComponent(name)))
    }

    private static func newResult(engine: String, kind: String, model: String, loadSeconds: Double) -> [String: Any] {
        ["engine": engine, "kind": kind, "model": model, "load_s": loadSeconds, "step": 0.5, "batch": [], "stream": []]
    }

    private static func samples(_ path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let pcm = data.subdata(in: 44..<data.count)  // prep.py writes canonical 44-byte headers
        return ParakeetEngine.pcm16ToFloat32(pcm)
    }

    private static func runBatch(
        root: URL, into result: inout [String: Any], transcribe: ([Float]) async throws -> [TimedWord]
    ) async throws {
        var batch: [[String: Any]] = []
        for item in try items(root, batchManifest) {
            let audio = try samples(item.wav) + [Float](repeating: 0, count: 8_000)
            let started = Date()
            let words = try await transcribe(audio)
            batch.append(["id": item.id, "hyp": words.map(\.text).joined(separator: " "),
                          "audio_s": item.seconds, "ms": Date().timeIntervalSince(started) * 1000])
        }
        result["batch"] = batch
    }

    private static func runStream(
        root: URL, into result: inout [String: Any], name: String,
        transcribe: ([Float]) async throws -> [TimedWord]
    ) async throws {
        var stream: [[String: Any]] = []
        for item in try items(root, streamManifest) {
            let audio = try samples(item.wav)
            var streamer = LocalAgreementStreamer()
            var snapshots: [[String]] = []
            var passMs: [Double] = []
            var offset = 0
            while offset < audio.count {
                let end = min(offset + 1_600, audio.count)
                if streamer.append(Array(audio[offset..<end])) {
                    let started = Date()
                    let pass = streamer.makePass(final: false)
                    let words = try await transcribe(pass.samples)
                    if let snap = streamer.applyPass(pass, words: pass.samples.isEmpty ? [] : words) {
                        snapshots.append([snap.committed, snap.draft])
                    }
                    passMs.append(Date().timeIntervalSince(started) * 1000)
                }
                offset = end
            }
            let started = Date()
            let pass = streamer.makePass(final: true)
            _ = streamer.applyPass(pass, words: pass.samples.isEmpty ? [] : try await transcribe(pass.samples))
            stream.append(["id": item.id, "audio_s": item.seconds, "snapshots": snapshots, "pass_ms": passMs,
                           "final": streamer.finalText(), "final_ms": Date().timeIntervalSince(started) * 1000])
            print("BENCH \(name) stream \(item.id) passes=\(passMs.count)")
        }
        result["stream"] = stream
    }

    private static func write(_ result: [String: Any], root: URL, name: String) throws {
        let dir = root.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result).write(to: dir.appendingPathComponent("\(name).json"))
        print("BENCH \(name) wrote results")
    }
}
