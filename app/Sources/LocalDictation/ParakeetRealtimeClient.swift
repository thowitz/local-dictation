import Foundation
import os

/// In-process realtime client for Parakeet TDT.
///
/// Speaks the same `DictationRealtimeClient` surface as the WebSocket client, but:
/// - `connect` / `disconnect` track model readiness (no socket)
/// - `sendAudio` buffers 16 kHz PCM16
/// - `commitFinal` batch-transcribes the buffer and emits one delta + done
/// - `clearBuffer` discards audio (cancellation)
///
/// Parakeet TDT is a batch / sliding-window model, not true streaming ASR. Dictation
/// therefore inserts text on finalize (release / stop), not token-by-token while speaking.
final class ParakeetRealtimeClient: DictationRealtimeClient, @unchecked Sendable {
    private struct State: Sendable {
        var callbacks = RealtimeClient.Callbacks()
        var connectionState: RealtimeClient.ConnectionState = .disconnected
        var audioBuffer = Data()
        var sessionID = UUID()
    }

    private let engine: ParakeetEngine
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let commitGate = OSAllocatedUnfairLock(initialState: Optional<Task<Void, Never>>.none)

    init(engine: ParakeetEngine) {
        self.engine = engine
    }

    var isConnected: Bool {
        state.withLock { $0.connectionState == .connected }
    }

    func setCallbacks(_ callbacks: RealtimeClient.Callbacks) {
        state.withLock { $0.callbacks = callbacks }
    }

    func connect() {
        commitGate.withLock { task in
            task?.cancel()
            task = nil
        }
        let connectingCallbacks: RealtimeClient.Callbacks = state.withLock { s in
            s.sessionID = UUID()
            s.audioBuffer.removeAll(keepingCapacity: true)
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
                AppLog.realtime.info("Parakeet realtime client connected (in-process)")
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
        commitGate.withLock { task in
            task?.cancel()
            task = nil
        }
        let result: (alreadyDisconnected: Bool, callbacks: RealtimeClient.Callbacks) = state.withLock { s in
            let already = s.connectionState == .disconnected
            s.sessionID = UUID()
            s.audioBuffer.removeAll(keepingCapacity: false)
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
        state.withLock { s in
            guard s.connectionState == .connected else { return }
            s.audioBuffer.append(pcm16)
        }
    }

    @discardableResult
    func commitFinal() -> Bool {
        let snapshot: (pcm: Data, sessionID: UUID, connected: Bool) = state.withLock { s in
            guard s.connectionState == .connected else {
                return (Data(), s.sessionID, false)
            }
            let pcm = s.audioBuffer
            s.audioBuffer.removeAll(keepingCapacity: true)
            return (pcm, s.sessionID, true)
        }
        guard snapshot.connected else { return false }

        let engine = self.engine
        let sessionID = snapshot.sessionID
        let pcm = snapshot.pcm
        let task = Task { [weak self] in
            await Self.runCommit(
                client: self,
                engine: engine,
                pcm: pcm,
                sessionID: sessionID
            )
        }
        commitGate.withLock { current in
            current?.cancel()
            current = task
        }
        return true
    }

    @discardableResult
    func clearBuffer() -> Bool {
        commitGate.withLock { task in
            task?.cancel()
            task = nil
        }
        let cbs = state.withLock { s -> RealtimeClient.Callbacks in
            s.audioBuffer.removeAll(keepingCapacity: true)
            s.sessionID = UUID()
            return s.callbacks
        }
        cbs.onBufferCleared?()
        return true
    }

    // MARK: - Internals

    private static func runCommit(
        client: ParakeetRealtimeClient?,
        engine: ParakeetEngine,
        pcm: Data,
        sessionID: UUID
    ) async {
        guard let client else { return }

        do {
            let text = try await engine.transcribe(pcm16: pcm)
            let snapshot = client.state.withLock { s -> (stillCurrent: Bool, callbacks: RealtimeClient.Callbacks) in
                let still = s.sessionID == sessionID && s.connectionState == .connected
                return (still, s.callbacks)
            }
            guard snapshot.stillCurrent else { return }

            if !text.isEmpty {
                snapshot.callbacks.onDelta?(text)
            }
            snapshot.callbacks.onDone?(text)
            AppLog.realtime.info(
                "Parakeet commit complete — chars=\(text.count, privacy: .public) pcmBytes=\(pcm.count, privacy: .public)"
            )
        } catch {
            let snapshot = client.state.withLock { s -> (stillCurrent: Bool, callbacks: RealtimeClient.Callbacks) in
                let still = s.sessionID == sessionID && s.connectionState == .connected
                return (still, s.callbacks)
            }
            guard snapshot.stillCurrent else { return }
            AppLog.realtime.error(
                "Parakeet commit failed: \(error.localizedDescription, privacy: .public)"
            )
            snapshot.callbacks.onError?(error.localizedDescription)
        }
    }
}
