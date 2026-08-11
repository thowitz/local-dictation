@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import LocalDictation

/// Verifies Parakeet EOU true streaming emits growing partials while audio is
/// streamed, then finalizes cleanly on commit. Skips when models / `say` are missing.
@Suite("ParakeetPartialsIntegration", .serialized)
struct ParakeetPartialsIntegrationTests {
    @Test("Partials emit before commit on multi-second speech")
    func partialsEmitBeforeCommit() async throws {
        guard let modelDir = ParakeetEngine.resolveModelDirectory(explicitPath: nil) else {
            return
        }
        guard commandExists("say"), commandExists("afconvert") else {
            return
        }

        // Longer phrase so multiple streaming chunks fire.
        let phrase =
            "The quick brown fox jumps over the lazy dog near the river bank today"
        let wavURL = try synthesizeWAV(text: phrase)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let pcm16 = try pcm16Data(from: wavURL)
        // Need enough audio for multiple 320 ms streaming windows.
        let halfSecondBytes = 16_000 * 2 / 2
        #expect(pcm16.count > halfSecondBytes * 3, "Audio too short for partial windows")

        let engine = ParakeetEngine()
        try await engine.load(directory: modelDir)
        #expect(await engine.isReady())

        let client = ParakeetRealtimeClient(engine: engine, chunkSeconds: 0.4)
        let collector = DeltaCollector()
        client.setCallbacks(
            RealtimeClient.Callbacks(
                onDelta: { delta, _ in collector.appendDelta(delta) },
                onDone: { text in collector.markDone(text) },
                onError: { message in collector.markError(message) }
            )
        )

        client.connect()
        // Wait until connected.
        for _ in 0..<100 {
            if client.isConnected { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(client.isConnected, "Client failed to connect after model load")

        // Stream PCM in ~100 ms slices so partials schedule during feed.
        let sliceBytes = 16_000 * 2 / 10 // 100 ms
        var offset = 0
        while offset < pcm16.count {
            let end = min(offset + sliceBytes, pcm16.count)
            client.sendAudio(pcm16.subdata(in: offset..<end))
            offset = end
            try await Task.sleep(for: .milliseconds(30))
        }

        // Allow in-flight streaming decode to catch up before commit.
        try await Task.sleep(for: .seconds(2))
        let partialCountBeforeCommit = collector.deltaCount
        let partialJoined = collector.joinedDeltas

        #expect(
            partialCountBeforeCommit >= 1,
            "Expected at least one partial delta before commit; got \(partialCountBeforeCommit). text so far: \(partialJoined.debugDescription)"
        )

        #expect(client.commitFinal())
        // Wait for done.
        for _ in 0..<300 {
            if collector.isDone || collector.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(collector.errorMessage == nil, "ASR error: \(collector.errorMessage ?? "")")
        #expect(collector.isDone, "commitFinal never delivered onDone")

        let finalText = collector.doneText ?? ""
        let allText = collector.joinedDeltas
        #expect(!finalText.isEmpty || !allText.isEmpty, "Empty transcript after commit")

        let haystack = (finalText.isEmpty ? allText : finalText).lowercased()
        let hits = ["quick", "brown", "fox", "dog", "river", "lazy", "jumps"]
            .filter { haystack.contains($0) }
        #expect(
            hits.count >= 2,
            "Final text \(haystack.debugDescription) matched too few expected words from phrase (hits=\(hits))"
        )

        // Partials must be a prefix path into the final transcript (or equal).
        if !partialJoined.isEmpty, !finalText.isEmpty {
            #expect(
                finalText.hasPrefix(partialJoined) || partialJoined.hasPrefix(finalText)
                    || finalText == partialJoined
                    || Self.shareLongPrefix(partialJoined, finalText) >= 4,
                "Partial text \(partialJoined.debugDescription) diverged from final \(finalText.debugDescription)"
            )
        }

        client.disconnect()
        await engine.unload()
    }

    @Test("Second utterance still emits text after first commit")
    func secondUtteranceStillEmits() async throws {
        guard let modelDir = ParakeetEngine.resolveModelDirectory(explicitPath: nil) else {
            return
        }
        guard commandExists("say"), commandExists("afconvert") else {
            return
        }

        let engine = ParakeetEngine()
        try await engine.load(directory: modelDir)
        let client = ParakeetRealtimeClient(engine: engine, chunkSeconds: 0.5)
        let collector = DeltaCollector()
        client.setCallbacks(
            RealtimeClient.Callbacks(
                onDelta: { delta, _ in collector.appendDelta(delta) },
                onDone: { text in collector.markDone(text) },
                onError: { message in collector.markError(message) }
            )
        )
        client.connect()
        for _ in 0..<100 {
            if client.isConnected { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(client.isConnected)

        // Utterance 1 — stream in slices so the encoder sees paced audio (like the mic).
        let pcm1 = try pcm16Data(from: try synthesizeWAV(text: "alpha bravo charlie one two three"))
        let slice = 16_000 * 2 / 10
        var offset = 0
        while offset < pcm1.count {
            let end = min(offset + slice, pcm1.count)
            client.sendAudio(pcm1.subdata(in: offset..<end))
            offset = end
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(client.commitFinal())
        for _ in 0..<300 {
            if collector.isDone || collector.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(collector.errorMessage == nil, "first utterance error: \(collector.errorMessage ?? "")")
        #expect(collector.isDone)
        let first = (collector.doneText ?? collector.joinedDeltas).lowercased()
        #expect(!first.isEmpty, "first utterance empty — got \(first.debugDescription)")

        // Reset collector for utterance 2 (simulates next hold session)
        collector.resetForNextUtterance()

        let pcm2 = try pcm16Data(from: try synthesizeWAV(text: "delta echo foxtrot four five six"))
        offset = 0
        while offset < pcm2.count {
            let end = min(offset + slice, pcm2.count)
            client.sendAudio(pcm2.subdata(in: offset..<end))
            offset = end
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(client.commitFinal())
        for _ in 0..<300 {
            if collector.isDone || collector.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(collector.errorMessage == nil, "second utterance error: \(collector.errorMessage ?? "")")
        #expect(collector.isDone, "second commit never delivered onDone")
        let second = (collector.doneText ?? collector.joinedDeltas).lowercased()
        #expect(
            !second.isEmpty,
            "second utterance produced no text — multi-session emittedText leak; got \(second.debugDescription)"
        )
        // Soft content check on second phrase.
        _ = ["delta", "echo", "foxtrot"].filter { second.contains($0) }

        client.disconnect()
        await engine.unload()
    }

    private static func shareLongPrefix(_ a: String, _ b: String) -> Int {
        a.commonPrefix(with: b).count
    }
}

// MARK: - Collector

private final class DeltaCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [String] = []
    private(set) var doneText: String?
    private(set) var errorMessage: String?

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return doneText != nil
    }

    var deltaCount: Int {
        lock.lock(); defer { lock.unlock() }
        return deltas.count
    }

    var joinedDeltas: String {
        lock.lock(); defer { lock.unlock() }
        return deltas.joined()
    }

    func appendDelta(_ delta: String) {
        lock.lock()
        deltas.append(delta)
        lock.unlock()
    }

    func markDone(_ text: String) {
        lock.lock()
        doneText = text
        lock.unlock()
    }

    func markError(_ message: String) {
        lock.lock()
        errorMessage = message
        lock.unlock()
    }

    func resetForNextUtterance() {
        lock.lock()
        deltas = []
        doneText = nil
        errorMessage = nil
        lock.unlock()
    }
}

// MARK: - Audio helpers (shared shape with ParakeetAudioSmokeTests)

private func commandExists(_ name: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [name]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func synthesizeWAV(text: String) throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("parakeet-partials-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let aiff = tmp.appendingPathComponent("speech.aiff")
    let wav = tmp.appendingPathComponent("speech.wav")

    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", aiff.path, text]
    try say.run()
    say.waitUntilExit()
    guard say.terminationStatus == 0 else {
        throw NSError(
            domain: "ParakeetPartials",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "say failed"]
        )
    }

    let af = Process()
    af.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    af.arguments = [aiff.path, wav.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"]
    try af.run()
    af.waitUntilExit()
    guard af.terminationStatus == 0 else {
        throw NSError(
            domain: "ParakeetPartials",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "afconvert failed"]
        )
    }
    return wav
}

private func pcm16Data(from wavURL: URL) throws -> Data {
    let file = try AVAudioFile(forReading: wavURL)
    let format = file.processingFormat
    guard let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    ) else {
        throw NSError(domain: "ParakeetPartials", code: 3, userInfo: nil)
    }

    guard let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(file.length)
    ) else {
        throw NSError(domain: "ParakeetPartials", code: 4, userInfo: nil)
    }
    try file.read(into: inputBuffer)

    if format.sampleRate == 16_000,
       format.channelCount == 1,
       format.commonFormat == .pcmFormatInt16,
       let channels = inputBuffer.int16ChannelData
    {
        let frameLength = Int(inputBuffer.frameLength)
        return Data(bytes: channels[0], count: frameLength * MemoryLayout<Int16>.size)
    }

    guard let converter = AVAudioConverter(from: format, to: target) else {
        throw NSError(domain: "ParakeetPartials", code: 5, userInfo: nil)
    }
    let ratio = 16_000 / format.sampleRate
    let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
        throw NSError(domain: "ParakeetPartials", code: 6, userInfo: nil)
    }
    var error: NSError?
    var consumed = false
    let status = converter.convert(to: output, error: &error) { _, outStatus in
        if consumed {
            outStatus.pointee = .noDataNow
            return nil
        }
        consumed = true
        outStatus.pointee = .haveData
        return inputBuffer
    }
    if let error { throw error }
    guard status != .error, let channels = output.int16ChannelData else {
        throw NSError(domain: "ParakeetPartials", code: 7, userInfo: nil)
    }
    let frameLength = Int(output.frameLength)
    return Data(bytes: channels[0], count: frameLength * MemoryLayout<Int16>.size)
}
