@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import LocalDictation

/// End-to-end Parakeet smoke: synthesize speech with macOS `say`, then transcribe
/// with the staged CoreML model. Skips cleanly when models or `say` are unavailable.
@Suite("ParakeetAudioSmoke")
struct ParakeetAudioSmokeTests {
    @Test("Parakeet transcribes synthesized speech audio")
    func parakeetTranscribesSynthesizedSpeech() async throws {
        guard let modelDir = ParakeetEngine.resolveModelDirectory(explicitPath: nil) else {
            // No staged models in this environment.
            return
        }
        guard Self.commandExists("say"), Self.commandExists("afconvert") else {
            return
        }

        let phrase = "Hello local dictation smoke test"
        let wavURL = try Self.synthesizeWAV(text: phrase)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let pcm16 = try Self.pcm16Data(from: wavURL)
        #expect(pcm16.count > 3200, "Expected more than 100 ms of audio")

        let engine = ParakeetEngine()
        try await engine.load(directory: modelDir)
        #expect(await engine.isReady())

        let text = try await engine.transcribe(pcm16: pcm16)
        await engine.unload()

        let normalized = text.lowercased()
        #expect(!normalized.isEmpty, "Transcript was empty for spoken phrase: \(phrase)")
        // Soft content check: at least one expected token should survive ASR.
        let hits = ["hello", "local", "dictation", "smoke", "test"].filter { normalized.contains($0) }
        #expect(
            hits.count >= 1,
            "Transcript \(text.debugDescription) did not contain any expected tokens from \(phrase.debugDescription)"
        )
    }

    // MARK: - Helpers

    private static func commandExists(_ name: String) -> Bool {
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

    private static func synthesizeWAV(text: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-smoke-\(UUID().uuidString)", isDirectory: true)
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
                domain: "ParakeetAudioSmoke",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "say failed with status \(say.terminationStatus)"]
            )
        }

        let af = Process()
        af.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        af.arguments = [
            aiff.path,
            wav.path,
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
        ]
        try af.run()
        af.waitUntilExit()
        guard af.terminationStatus == 0 else {
            throw NSError(
                domain: "ParakeetAudioSmoke",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "afconvert failed with status \(af.terminationStatus)"]
            )
        }
        return wav
    }

    private static func pcm16Data(from wavURL: URL) throws -> Data {
        let file = try AVAudioFile(forReading: wavURL)
        let format = file.processingFormat
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(
                domain: "ParakeetAudioSmoke",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create 16 kHz mono Int16 format"]
            )
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw NSError(
                domain: "ParakeetAudioSmoke",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate input buffer"]
            )
        }
        try file.read(into: inputBuffer)

        if format.sampleRate == 16_000,
           format.channelCount == 1,
           format.commonFormat == .pcmFormatInt16
        {
            let frameLength = Int(inputBuffer.frameLength)
            let byteCount = frameLength * MemoryLayout<Int16>.size
            guard let channels = inputBuffer.int16ChannelData else {
                throw NSError(
                    domain: "ParakeetAudioSmoke",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Missing int16 channel data"]
                )
            }
            return Data(bytes: channels[0], count: byteCount)
        }

        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(
                domain: "ParakeetAudioSmoke",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create audio converter"]
            )
        }
        let ratio = 16_000 / format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw NSError(
                domain: "ParakeetAudioSmoke",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate output buffer"]
            )
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
        guard status != .error else {
            throw NSError(
                domain: "ParakeetAudioSmoke",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed"]
            )
        }

        let frameLength = Int(output.frameLength)
        let byteCount = frameLength * MemoryLayout<Int16>.size
        guard let channels = output.int16ChannelData else {
            throw NSError(
                domain: "ParakeetAudioSmoke",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Missing converted int16 data"]
            )
        }
        return Data(bytes: channels[0], count: byteCount)
    }
}
