import Foundation
import os

/// In-process realtime client for Parakeet TDT (CoreML).
///
/// Speaks the same `DictationRealtimeClient` surface as the WebSocket client:
/// - `connect` / `disconnect` track model readiness (no socket)
/// - `sendAudio` buffers 16 kHz PCM16 and runs periodic partial re-transcribes
/// - `commitFinal` re-transcribes the full buffer and emits remaining delta + done
/// - `clearBuffer` discards audio (cancellation)
///
/// Partials re-transcribe the full utterance so far, then emit only the text
/// suffix beyond the last emitted prefix (safe for insert-only text paths).
final class ParakeetRealtimeClient: DictationRealtimeClient, @unchecked Sendable {
    private struct State: Sendable {
        var callbacks = RealtimeClient.Callbacks()
        var connectionState: RealtimeClient.ConnectionState = .disconnected
        var audioBuffer = Data()
        var sessionID = UUID()
        /// Full transcript text already delivered as deltas this session.
        var emittedText = ""
        /// Audio byte count when the last partial was scheduled.
        var lastPartialByteCount = 0
        var partialInFlight = false
    }

    private let engine: ParakeetEngine
    /// Minimum new PCM16 bytes before a partial re-transcribe (default ~1 s at 16 kHz mono).
    private let chunkBytes: Int
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let workGate = OSAllocatedUnfairLock(initialState: Optional<Task<Void, Never>>.none)

    /// - Parameters:
    ///   - engine: Shared Parakeet engine.
    ///   - chunkSeconds: New audio duration that triggers a partial. `0` disables partials.
    init(engine: ParakeetEngine, chunkSeconds: Double = 1.0) {
        self.engine = engine
        if chunkSeconds <= 0 {
            self.chunkBytes = Int.max
        } else {
            // 16 kHz mono Int16 → 2 bytes/sample.
            self.chunkBytes = max(1, Int(chunkSeconds * 16_000 * 2))
        }
    }

    var isConnected: Bool {
        state.withLock { $0.connectionState == .connected }
    }

    func setCallbacks(_ callbacks: RealtimeClient.Callbacks) {
        state.withLock { $0.callbacks = callbacks }
    }

    func connect() {
        workGate.withLock { task in
            task?.cancel()
            task = nil
        }
        let connectingCallbacks: RealtimeClient.Callbacks = state.withLock { s in
            s.sessionID = UUID()
            s.audioBuffer.removeAll(keepingCapacity: true)
            s.emittedText = ""
            s.lastPartialByteCount = 0
            s.partialInFlight = false
            s.connectionState = .connecting
            return s.callbacks
        }
        connectingCallbacks.onConnectionState?(.connecting)

        Task { [weak self] in
            guard let self else { return }
            let ready = await self.engine.isReady()
            if ready {
                let cbs = self.state.withLock { s -> RealtimeClient.Callbacks in
                    s.connectionState = .connected
                    return s.callbacks
                }
                cbs.onConnectionState?(.connected)
                AppLog.realtime.info("Parakeet realtime client connected (in-process, chunked)")
            } else {
                let cbs = self.state.withLock { s -> RealtimeClient.Callbacks in
                    s.connectionState = .disconnected
                    return s.callbacks
                }
                cbs.onConnectionState?(.disconnected)
                cbs.onError?("Parakeet models are not ready.")
                AppLog.realtime.error("Parakeet connect failed — models not ready")
            }
        }
    }

    func disconnect() {
        workGate.withLock { task in
            task?.cancel()
            task = nil
        }
        let result: (alreadyDisconnected: Bool, callbacks: RealtimeClient.Callbacks) = state.withLock { s in
            let already = s.connectionState == .disconnected
            s.sessionID = UUID()
            s.audioBuffer.removeAll(keepingCapacity: false)
            s.emittedText = ""
            s.lastPartialByteCount = 0
            s.partialInFlight = false
            s.connectionState = .disconnected
            return (already, s.callbacks)
        }
        if !result.alreadyDisconnected {
            result.callbacks.onConnectionState?(.disconnected)
        }
        AppLog.realtime.info("Parakeet realtime client disconnected")
    }

    func sendAudio(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        let shouldPartial: Bool = state.withLock { s in
            guard s.connectionState == .connected else { return false }
            s.audioBuffer.append(pcm16)
            let newBytes = s.audioBuffer.count - s.lastPartialByteCount
            return !s.partialInFlight && newBytes >= chunkBytes && chunkBytes != Int.max
        }
        if shouldPartial {
            schedulePartial()
        }
    }

    @discardableResult
    func commitFinal() -> Bool {
        let snapshot: (pcm: Data, sessionID: UUID, emitted: String, connected: Bool) = state.withLock { s in
            guard s.connectionState == .connected else {
                return (Data(), s.sessionID, s.emittedText, false)
            }
            let pcm = s.audioBuffer
            s.audioBuffer.removeAll(keepingCapacity: true)
            s.lastPartialByteCount = 0
            s.partialInFlight = true // block concurrent partials
            return (pcm, s.sessionID, s.emittedText, true)
        }
        guard snapshot.connected else { return false }

        let engine = self.engine
        let sessionID = snapshot.sessionID
        let pcm = snapshot.pcm
        let previouslyEmitted = snapshot.emitted
        let task = Task { [weak self] in
            await Self.runCommit(
                client: self,
                engine: engine,
                pcm: pcm,
                sessionID: sessionID,
                previouslyEmitted: previouslyEmitted
            )
        }
        workGate.withLock { current in
            current?.cancel()
            current = task
        }
        return true
    }

    @discardableResult
    func clearBuffer() -> Bool {
        workGate.withLock { task in
            task?.cancel()
            task = nil
        }
        let cbs = state.withLock { s -> RealtimeClient.Callbacks in
            s.audioBuffer.removeAll(keepingCapacity: true)
            s.emittedText = ""
            s.lastPartialByteCount = 0
            s.partialInFlight = false
            s.sessionID = UUID()
            return s.callbacks
        }
        cbs.onBufferCleared?()
        return true
    }

    // MARK: - Partials

    private func schedulePartial() {
        let snapshot: (pcm: Data, sessionID: UUID, emitted: String)? = state.withLock { s in
            guard s.connectionState == .connected, !s.partialInFlight else { return nil }
            s.partialInFlight = true
            s.lastPartialByteCount = s.audioBuffer.count
            return (s.audioBuffer, s.sessionID, s.emittedText)
        }
        guard let snapshot else { return }

        let engine = self.engine
        let task = Task { [weak self] in
            await Self.runPartial(
                client: self,
                engine: engine,
                pcm: snapshot.pcm,
                sessionID: snapshot.sessionID,
                previouslyEmitted: snapshot.emitted
            )
        }
        workGate.withLock { current in
            // Do not cancel an in-flight commit; partials are best-effort.
            if current == nil || current?.isCancelled == true {
                current = task
            }
        }
    }

    private static func runPartial(
        client: ParakeetRealtimeClient?,
        engine: ParakeetEngine,
        pcm: Data,
        sessionID: UUID,
        previouslyEmitted: String
    ) async {
        guard let client else { return }
        defer {
            client.state.withLock { s in
                if s.sessionID == sessionID {
                    s.partialInFlight = false
                }
            }
        }

        do {
            let text = try await engine.transcribe(pcm16: pcm)
            // Read the latest emitted text in case another partial already advanced it.
            let baseline = client.state.withLock { s -> String in
                guard s.sessionID == sessionID else { return previouslyEmitted }
                return s.emittedText
            }
            let delta = Self.incrementalDelta(full: text, previouslyEmitted: baseline)
            let snapshot = client.state.withLock { s -> (stillCurrent: Bool, callbacks: RealtimeClient.Callbacks) in
                let still = s.sessionID == sessionID && s.connectionState == .connected
                if still, !delta.isEmpty {
                    s.emittedText = baseline + delta
                }
                return (still, s.callbacks)
            }
            guard snapshot.stillCurrent else { return }
            if !delta.isEmpty {
                snapshot.callbacks.onDelta?(delta)
                AppLog.realtime.info(
                    "Parakeet partial delta chars=\(delta.count, privacy: .public) full=\(text.count, privacy: .public)"
                )
            }
        } catch {
            // Partials are best-effort; log and continue listening.
            AppLog.realtime.error(
                "Parakeet partial failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func runCommit(
        client: ParakeetRealtimeClient?,
        engine: ParakeetEngine,
        pcm: Data,
        sessionID: UUID,
        previouslyEmitted: String
    ) async {
        guard let client else { return }

        do {
            let text = try await engine.transcribe(pcm16: pcm)
            // Use the latest emitted baseline (partials may have advanced it).
            let baseline = client.state.withLock { s -> String in
                guard s.sessionID == sessionID else { return previouslyEmitted }
                return s.emittedText
            }
            let delta = Self.incrementalDelta(full: text, previouslyEmitted: baseline)
            let snapshot = client.state.withLock { s -> (stillCurrent: Bool, callbacks: RealtimeClient.Callbacks) in
                let still = s.sessionID == sessionID && s.connectionState == .connected
                if still {
                    // Reset utterance state so the next hold session starts clean.
                    // Leaving emittedText set was the multi-session bug: second
                    // commit computed an empty delta against the first transcript.
                    s.emittedText = ""
                    s.lastPartialByteCount = 0
                    s.partialInFlight = false
                }
                return (still, s.callbacks)
            }
            guard snapshot.stillCurrent else { return }

            if !delta.isEmpty {
                snapshot.callbacks.onDelta?(delta)
            }
            snapshot.callbacks.onDone?(text)
            AppLog.realtime.info(
                "Parakeet commit complete — chars=\(text.count, privacy: .public) pcmBytes=\(pcm.count, privacy: .public) remainingDelta=\(delta.count, privacy: .public)"
            )
        } catch {
            let snapshot = client.state.withLock { s -> (stillCurrent: Bool, callbacks: RealtimeClient.Callbacks) in
                let still = s.sessionID == sessionID && s.connectionState == .connected
                if still {
                    s.emittedText = ""
                    s.lastPartialByteCount = 0
                    s.partialInFlight = false
                }
                return (still, s.callbacks)
            }
            guard snapshot.stillCurrent else { return }
            AppLog.realtime.error(
                "Parakeet commit failed: \(error.localizedDescription, privacy: .public)"
            )
            snapshot.callbacks.onError?(error.localizedDescription)
        }
    }

    /// Returns text that can be appended after `previouslyEmitted` when the model
    /// re-transcribes a growing utterance. Only emits when the new full text
    /// still starts with the prior emit (insert-only text paths cannot revise).
    static func incrementalDelta(full: String, previouslyEmitted: String) -> String {
        if previouslyEmitted.isEmpty {
            return full
        }
        if full.hasPrefix(previouslyEmitted) {
            return String(full.dropFirst(previouslyEmitted.count))
        }
        // Model revised earlier words — do not emit a conflicting prefix.
        // On commit the caller still gets the full text via onDone for logging.
        let common = full.commonPrefix(with: previouslyEmitted)
        if common.count >= previouslyEmitted.count {
            return String(full.dropFirst(previouslyEmitted.count))
        }
        return ""
    }
}
