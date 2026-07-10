@preconcurrency import AVFoundation
import Foundation
import os

/// Captures microphone audio via AVAudioEngine and converts to 16 kHz mono Int16 PCM.
final class AudioCapture: @unchecked Sendable {
    typealias ChunkHandler = @Sendable (Data) -> Void

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var chunkHandler: ChunkHandler?
    private var isRunning = false
    private var pendingBuffer = Data()

    /// Target chunk size in bytes (~100 ms of 16 kHz mono Int16 = 3200 bytes).
    private let targetChunkBytes = 3200
    private let minChunkBytes = 2560 // ~80 ms
    private let maxChunkBytes = 5120 // ~160 ms

    private let outputFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            preconditionFailure("Unable to create 16 kHz mono Int16 format")
        }
        return format
    }()

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start(chunkHandler: @escaping ChunkHandler) throws {
        lock.lock()
        defer { lock.unlock() }

        if isRunning {
            self.chunkHandler = chunkHandler
            return
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(
                domain: "LocalDictation.AudioCapture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid microphone input format."]
            )
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(
                domain: "LocalDictation.AudioCapture",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to create audio converter (\(Int(inputFormat.sampleRate)) Hz → 16 kHz).",
                ]
            )
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter = converter
        self.chunkHandler = chunkHandler
        pendingBuffer.removeAll(keepingCapacity: true)

        let bufferSize: AVAudioFrameCount = 1024
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
            [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        AppLog.audio.info(
            "Capture started inputRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)"
        )
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        chunkHandler = nil
        pendingBuffer.removeAll(keepingCapacity: false)
        isRunning = false
        AppLog.audio.info("Capture stopped")
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard isRunning, let converter, let handler = chunkHandler else {
            lock.unlock()
            return
        }
        let outputFormat = self.outputFormat
        lock.unlock()

        guard let pcm = Self.convert(buffer: buffer, converter: converter, outputFormat: outputFormat)
        else {
            return
        }

        lock.lock()
        pendingBuffer.append(pcm)
        var chunks: [Data] = []
        while pendingBuffer.count >= minChunkBytes {
            let size: Int
            if pendingBuffer.count >= maxChunkBytes {
                size = maxChunkBytes
            } else if pendingBuffer.count >= targetChunkBytes {
                size = targetChunkBytes
            } else {
                break
            }
            let chunk = pendingBuffer.prefix(size)
            chunks.append(Data(chunk))
            pendingBuffer.removeFirst(size)
        }
        lock.unlock()

        for chunk in chunks {
            handler(chunk)
        }
    }

    private static func convert(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> Data? {
        guard buffer.frameLength > 0 else { return nil }

        let ratio = outputFormat.sampleRate / max(1, buffer.format.sampleRate)
        let estimated = max(1, Int(ceil(Double(buffer.frameLength) * ratio)) + 32)
        guard let out = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(estimated)
        ) else {
            return nil
        }

        let source = buffer
        final class Flag: @unchecked Sendable {
            var value = false
        }
        let consumed = Flag()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if !consumed.value {
                consumed.value = true
                outStatus.pointee = .haveData
                return source
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard error == nil, status == .haveData || status == .inputRanDry else { return nil }
        let frames = Int(out.frameLength)
        guard frames > 0, let channels = out.int16ChannelData else { return nil }
        let byteCount = frames * MemoryLayout<Int16>.size
        return Data(bytes: channels[0], count: byteCount)
    }
}
