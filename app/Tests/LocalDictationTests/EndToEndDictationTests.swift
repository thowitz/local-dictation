import Foundation
import Testing
@testable import LocalDictation

/// Opt-in end-to-end check of the real transcript path on recorded speech:
/// realtime client → ``DictationTypist`` → a modelled text field.
///
///     LD_E2E_CASES=/dir/with/name.wav+name.txt \
///     LD_E2E_PORT=8472   # optional: also run against a parakeet-mlx server
///     LD_E2E_HOST=…      # optional: server host (default 127.0.0.1)
///     swift test --filter EndToEndDictation
///
/// Audio is streamed in 100 ms chunks at 2× real time. For every case it
/// asserts the field ends up holding exactly the final transcript after the
/// pre-existing text, and that no edit backspaced more than the typist cap.
@Suite("EndToEndDictation", .serialized)
struct EndToEndDictationTests {
    private static var casesDirectory: URL? {
        ProcessInfo.processInfo.environment["LD_E2E_CASES"].map { URL(fileURLWithPath: $0) }
    }

    @Test("Parakeet CoreML streams real speech into a field without rewrites")
    func coreML() async throws {
        guard let dir = Self.casesDirectory,
              let modelDir = ParakeetEngine.resolveModelDirectory(explicitPath: nil)
        else { return }
        let engine = ParakeetEngine()
        try await engine.load(directory: modelDir)
        let client = ParakeetRealtimeClient(engine: engine, chunkSeconds: 0.5)
        try await runCases(in: dir, provider: "coreml", client: client)
        await engine.unload()
    }

    @Test("Parakeet MLX server streams real speech into a field without rewrites")
    func mlxServer() async throws {
        guard let dir = Self.casesDirectory,
              let port = ProcessInfo.processInfo.environment["LD_E2E_PORT"]
        else { return }
        let host = ProcessInfo.processInfo.environment["LD_E2E_HOST"] ?? "127.0.0.1"
        let client = RealtimeClient(endpoint: URL(string: "ws://\(host):\(port)/v1/realtime")!)
        try await runCases(in: dir, provider: "mlx", client: client)
    }

    // MARK: - Harness

    private func runCases(in dir: URL, provider: String, client: some DictationRealtimeClient) async throws {
        let recorder = Recorder()
        client.setCallbacks(
            RealtimeClient.Callbacks(
                onTranscript: { recorder.event(.transcript($0)) },
                onDone: { recorder.event(.done($0)) },
                onConnectionState: { recorder.connected = $0 == .connected },
                onError: { recorder.event(.error($0)) }
            )
        )
        client.connect()
        for _ in 0..<200 where !recorder.connected {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(recorder.connected, "\(provider): client did not connect")

        let wavs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for wav in wavs {
            let reference = (try? String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)) ?? ""
            let pcm = try Self.pcm16(fromWAV: wav)
            recorder.reset()

            let slice = 3_200
            var offset = 0
            let started = Date()
            while offset < pcm.count {
                let end = min(offset + slice, pcm.count)
                client.sendAudio(pcm.subdata(in: offset..<end))
                offset = end
                try await Task.sleep(for: .milliseconds(50))
            }
            let released = Date()
            #expect(client.commitFinal())
            for _ in 0..<600 where !recorder.isDone {
                try await Task.sleep(for: .milliseconds(20))
            }
            let finalLatency = Date().timeIntervalSince(released)
            let result = recorder.result()
            let name = "\(provider)/\(wav.deletingPathExtension().lastPathComponent)"
            print(
                "E2E \(name) audio=\(String(format: "%.1f", Double(pcm.count) / 32_000))s "
                    + "wer=\(String(format: "%.3f", Self.wer(result.final, reference))) "
                    + "maxDel=\(result.maxDelete) totalDel=\(result.totalDelete) "
                    + "realign=\(result.realigns) updates=\(result.updates) "
                    + "firstText=\(result.firstTextAt.map { String(format: "%.2fs", $0.timeIntervalSince(started)) } ?? "-") "
                    + "releaseToDone=\(String(format: "%.2fs", finalLatency))"
            )
            print("E2E \(name) text: \(result.screen)")
            #expect(result.error == nil, "\(name): \(result.error ?? "")")
            #expect(recorder.isDone, "\(name): no done")
            #expect(result.committedAppendOnly, "\(name): committed text was revised")
            #expect(result.maxDelete <= DictationTypist.defaultMaxRevision, "\(name)")
            #expect(result.screen == Recorder.prompt + result.final, "\(name): field != final transcript")
        }
        client.disconnect()
    }

    private enum Event {
        case transcript(TranscriptEvent)
        case done(String)
        case error(String)
    }

    private final class Recorder: @unchecked Sendable {
        static let prompt = "PROMPT: "
        private let lock = NSLock()
        private var typist = DictationTypist()
        private var screen = ScreenModel(prompt)
        private var committed: [String] = []
        private var final: String?
        private var error: String?
        private var maxDelete = 0
        private var totalDelete = 0
        private var updates = 0
        private var firstTextAt: Date?
        private var _connected = false

        var connected: Bool {
            get { lock.withLock { _connected } }
            set { lock.withLock { _connected = newValue } }
        }

        var isDone: Bool { lock.withLock { final != nil || error != nil } }

        func reset() {
            lock.withLock {
                typist = DictationTypist()
                screen = ScreenModel(Self.prompt)
                committed = []
                final = nil
                error = nil
                maxDelete = 0
                totalDelete = 0
                updates = 0
                firstTextAt = nil
            }
        }

        func event(_ event: Event) {
            lock.withLock {
                let edit: TypingEdit
                switch event {
                case .transcript(.append(let delta)):
                    edit = typist.append(delta)
                case .transcript(.snapshot(let snapshot)):
                    committed.append(snapshot.committed)
                    edit = typist.apply(committed: snapshot.committed, draft: snapshot.draft)
                case .done(let text):
                    edit = typist.finish(finalText: text)
                    final = text
                case .error(let message):
                    error = message
                    return
                }
                updates += 1
                if firstTextAt == nil, !edit.insert.isEmpty { firstTextAt = Date() }
                maxDelete = max(maxDelete, edit.deleteCount)
                totalDelete += edit.deleteCount
                screen.apply(edit)
            }
        }

        struct Result {
            var screen: String
            var final: String
            var error: String?
            var maxDelete: Int
            var totalDelete: Int
            var realigns: Int
            var updates: Int
            var firstTextAt: Date?
            var committedAppendOnly: Bool
        }

        func result() -> Result {
            lock.withLock {
                Result(
                    screen: screen.text,
                    final: final ?? "",
                    error: error,
                    maxDelete: maxDelete,
                    totalDelete: totalDelete,
                    realigns: typist.realignCount,
                    updates: updates,
                    firstTextAt: firstTextAt,
                    committedAppendOnly: zip(committed, committed.dropFirst()).allSatisfy { $1.hasPrefix($0) }
                )
            }
        }
    }

    /// PCM16 payload of a 16 kHz mono WAV (as produced by `afconvert -d LEI16@16000`).
    private static func pcm16(fromWAV url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        var index = 12
        while index + 8 <= data.count {
            let id = String(decoding: data[index..<(index + 4)], as: UTF8.self)
            let size = data[(index + 4)..<(index + 8)].enumerated()
                .reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
            if id == "data" {
                return data.subdata(in: (index + 8)..<min(data.count, index + 8 + size))
            }
            index += 8 + size + (size & 1)
        }
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "no data chunk in \(url.path)"])
    }

    private static func wer(_ hypothesis: String, _ reference: String) -> Double {
        let h = hypothesis.split(whereSeparator: \.isWhitespace).map(DictationTypist.normalize).filter { !$0.isEmpty }
        let r = reference.split(whereSeparator: \.isWhitespace).map(DictationTypist.normalize).filter { !$0.isEmpty }
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var row = Array(0...h.count)
        for i in 1...r.count {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: h.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (r[i - 1] == h[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return Double(row[h.count]) / Double(r.count)
    }
}
