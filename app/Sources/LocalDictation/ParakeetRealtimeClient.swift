import Foundation
import os

/// In-process realtime client for Parakeet **TDT 0.6B** (CoreML).
///
/// Speaks the same `DictationRealtimeClient` surface as the WebSocket client:
/// - `connect` / `disconnect` track model readiness
/// - `sendAudio` feeds PCM into the engine's ``LocalAgreementStreamer``; each
///   pass that changes the text emits a committed/draft snapshot
/// - `commitFinal` drains queued audio, runs the final pass, then emits done
/// - `clearBuffer` cancels the utterance
///
/// The client does not track typed text — the controller's
/// ``DictationTypist`` is the single owner of what is on screen.
final class ParakeetRealtimeClient: DictationRealtimeClient, @unchecked Sendable {
    private struct State: Sendable {
        var callbacks = RealtimeClient.Callbacks()
        var connectionState: RealtimeClient.ConnectionState = .disconnected
        var finalizing = false
        /// Bumped whenever queued feed/commit work must become stale.
        var generation: UInt64 = 0
        var utteranceStarted = false
    }

    private let engine: ParakeetEngine
    private let chunkSeconds: Double
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Tail of the serial feed → commit chain for the current utterance.
    private let feedQueue = OSAllocatedUnfairLock(initialState: Optional<Task<Void, Never>>.none)

    /// - Parameters:
    ///   - engine: Shared Parakeet TDT engine.
    ///   - chunkSeconds: Pass cadence (`parakeetChunkSeconds`), clamped by the engine.
    init(engine: ParakeetEngine, chunkSeconds: Double = 0.5) {
        self.engine = engine
        self.chunkSeconds = chunkSeconds > 0 ? chunkSeconds : 0.5
    }

    var isConnected: Bool {
        state.withLock { $0.connectionState == .connected }
    }

    func setCallbacks(_ callbacks: RealtimeClient.Callbacks) {
        state.withLock { $0.callbacks = callbacks }
    }

    func connect() {
        cancelFeedWork()
        let connectingCallbacks: RealtimeClient.Callbacks = state.withLock { s in
            s.finalizing = false
            s.utteranceStarted = false
            s.generation &+= 1
            s.connectionState = .connecting
            return s.callbacks
        }
        connectingCallbacks.onConnectionState?(.connecting)

        Task { [weak self] in
            guard let self else { return }
            await self.engine.setChunkSeconds(self.chunkSeconds)
            let ready = await self.engine.isReady()
            let cbs = self.state.withLock { s -> RealtimeClient.Callbacks in
                s.connectionState = ready ? .connected : .disconnected
                s.finalizing = false
                s.utteranceStarted = false
                return s.callbacks
            }
            if ready {
                cbs.onConnectionState?(.connected)
                AppLog.realtime.info("Parakeet TDT realtime client connected")
            } else {
                cbs.onConnectionState?(.disconnected)
                cbs.onError?("Parakeet models are not ready.")
                AppLog.realtime.error("Parakeet TDT connect failed — models not ready")
            }
        }
    }

    func disconnect() {
        cancelFeedWork()
        let cbs = state.withLock { s -> RealtimeClient.Callbacks in
            s.generation &+= 1
            s.utteranceStarted = false
            s.finalizing = false
            s.connectionState = .disconnected
            return s.callbacks
        }
        Task { [engine] in await engine.cancelUtterance() }
        cbs.onConnectionState?(.disconnected)
        AppLog.realtime.info("Parakeet TDT realtime client disconnected")
    }

    func sendAudio(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        let snapshot: (ok: Bool, generation: UInt64, needStart: Bool) = state.withLock { s in
            guard s.connectionState == .connected, !s.finalizing else { return (false, 0, false) }
            let needStart = !s.utteranceStarted
            s.utteranceStarted = true
            return (true, s.generation, needStart)
        }
        guard snapshot.ok else { return }

        enqueue { [weak self] in
            guard let self, self.isCurrent(snapshot.generation) else { return }
            do {
                if snapshot.needStart {
                    try await self.engine.beginUtterance()
                }
                guard let update = try await self.engine.processAudio(pcm16: pcm16) else { return }
                let cbs = self.state.withLock { $0.callbacks }
                guard self.isCurrent(snapshot.generation) else { return }
                cbs.onTranscript?(.snapshot(update))
            } catch {
                if !Task.isCancelled {
                    AppLog.realtime.error(
                        "Parakeet TDT process failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    @discardableResult
    func commitFinal() -> Bool {
        let generation: UInt64? = state.withLock { s in
            guard s.connectionState == .connected else { return nil }
            s.finalizing = true
            return s.generation
        }
        guard let generation else { return false }

        // Runs after every queued feed task, so the final pass sees all audio.
        enqueue { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            do {
                let text = try await self.engine.finishUtterance()
                let cbs = self.state.withLock { s -> RealtimeClient.Callbacks? in
                    guard s.generation == generation, s.connectionState == .connected else { return nil }
                    s.finalizing = false
                    s.utteranceStarted = false
                    s.generation &+= 1
                    return s.callbacks
                }
                guard let cbs else { return }
                cbs.onDone?(text)
                AppLog.realtime.info("Parakeet TDT commit complete — chars=\(text.count, privacy: .public)")
            } catch {
                let cbs = self.state.withLock { s -> RealtimeClient.Callbacks? in
                    guard s.generation == generation, s.connectionState == .connected else { return nil }
                    s.finalizing = false
                    s.utteranceStarted = false
                    s.generation &+= 1
                    return s.callbacks
                }
                guard let cbs else { return }
                AppLog.realtime.error(
                    "Parakeet TDT commit failed: \(error.localizedDescription, privacy: .public)"
                )
                cbs.onError?(error.localizedDescription)
            }
        }
        return true
    }

    @discardableResult
    func clearBuffer() -> Bool {
        cancelFeedWork()
        let cbs = state.withLock { s -> RealtimeClient.Callbacks in
            s.finalizing = false
            s.utteranceStarted = false
            s.generation &+= 1
            return s.callbacks
        }
        Task { [engine] in await engine.cancelUtterance() }
        cbs.onBufferCleared?()
        return true
    }

    // MARK: - Internals

    private func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.connectionState == .connected && $0.generation == generation }
    }

    /// Append work to the serial feed chain (each task awaits the previous).
    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        feedQueue.withLock { tail in
            let previous = tail
            tail = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                await work()
            }
        }
    }

    private func cancelFeedWork() {
        feedQueue.withLock { task in
            task?.cancel()
            task = nil
        }
    }
}
