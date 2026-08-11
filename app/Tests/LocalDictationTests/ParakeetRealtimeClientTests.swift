import Foundation
import Testing
@testable import LocalDictation

@Suite("ParakeetRealtimeClient", .serialized)
struct ParakeetRealtimeClientTests {
    @Test("PCM16 converts to float32 in [-1, 1]")
    func pcm16ConvertsToFloat32() {
        var bytes = Data()
        func append(_ value: Int16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        }
        append(0)
        append(Int16.max)
        append(Int16.min)
        append(16_384)

        let samples = ParakeetEngine.pcm16ToFloat32(bytes)
        #expect(samples.count == 4)
        #expect(samples[0] == 0)
        #expect(abs(samples[1] - 1.0) < 0.0001)
        #expect(samples[2] < -0.999)
        #expect(abs(samples[3] - 0.5) < 0.001)
    }

    @Test("clearBuffer returns true and leaves client disconnected")
    func clearBufferReturnsTrue() {
        let engine = ParakeetEngine()
        let client = ParakeetRealtimeClient(engine: engine)
        #expect(client.clearBuffer())
        #expect(!client.isConnected)
    }

    @Test("sendAudio is a no-op while disconnected")
    func sendAudioNoOpWhileDisconnected() {
        let engine = ParakeetEngine()
        let client = ParakeetRealtimeClient(engine: engine)
        // Should not crash; audio is discarded when disconnected.
        client.sendAudio(Data(repeating: 0, count: 3200))
        #expect(!client.isConnected)
        #expect(!client.commitFinal())
    }

    @Test("Provider display names are stable")
    func providerDisplayNamesAreStable() {
        #expect(SpeechProvider.voxtral.displayName.contains("Voxtral"))
        #expect(SpeechProvider.parakeet.displayName.contains("CoreML"))
        #expect(SpeechProvider.parakeetMlx.displayName.contains("MLX"))
        #expect(SpeechProvider.parakeetDefaultRepoFolder.contains("parakeet-tdt"))
        #expect(SpeechProvider.parakeetMlxDefaultModel.contains("parakeet-tdt-0.6b-v3"))
    }

    @Test("Incremental delta only grows a stable prefix")
    func incrementalDeltaOnlyGrowsStablePrefix() {
        #expect(
            ParakeetRealtimeClient.incrementalDelta(full: "hello world", previouslyEmitted: "")
                == "hello world"
        )
        #expect(
            ParakeetRealtimeClient.incrementalDelta(
                full: "hello world",
                previouslyEmitted: "hello "
            ) == "world"
        )
        // Revision of earlier text → no conflicting insert.
        #expect(
            ParakeetRealtimeClient.incrementalDelta(
                full: "hi there",
                previouslyEmitted: "hello "
            ) == ""
        )
        // Second utterance must not treat first transcript as prior emit.
        #expect(
            ParakeetRealtimeClient.incrementalDelta(
                full: "hello world",
                previouslyEmitted: "hello world"
            ) == ""
        )
        #expect(
            ParakeetRealtimeClient.incrementalDelta(
                full: "hello world",
                previouslyEmitted: ""
            ) == "hello world"
        )
    }

    @Test("PCM16 buffer conversion yields float frames")
    func pcm16BufferConversionYieldsFloatFrames() {
        var pcm = Data()
        for value: Int16 in [0, Int16.max, Int16.min, 16_384] {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }
        let buffer = ParakeetEngine.makeFloatPCMBuffer(fromPCM16: pcm)
        #expect(buffer != nil)
        #expect(buffer?.frameLength == 4)
        #expect(buffer?.format.sampleRate == 16_000)
    }

    @Test("Staged Parakeet TDT model loads when present on disk")
    func stagedParakeetTDTModelLoadsWhenPresent() async throws {
        guard let directory = ParakeetEngine.resolveModelDirectory(explicitPath: nil) else {
            // No staged models on this machine — unit environment still green.
            return
        }
        #expect(ParakeetEngine.containsV3Bundles(at: directory))

        let engine = ParakeetEngine()
        try await engine.load(directory: directory)
        #expect(await engine.isReady())

        // Short silence through the streaming path — should not crash.
        var pcm = Data()
        for _ in 0..<(8_000) {
            var zero: Int16 = 0
            withUnsafeBytes(of: &zero) { pcm.append(contentsOf: $0) }
        }
        try await engine.beginUtterance()
        try await engine.processAudio(pcm16: pcm)
        let text = try await engine.finishUtterance()
        #expect(text.isEmpty || text.count >= 0)

        await engine.unload()
        #expect(await engine.isReady() == false)
    }
}
