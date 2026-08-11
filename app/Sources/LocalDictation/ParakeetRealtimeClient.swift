import Foundation
import os

/// In-process realtime client for Parakeet **TDT 0.6B** sliding-window partials.
///
/// Speaks the same `DictationRealtimeClient` surface as the WebSocket client:
/// - `connect` / `disconnect` track model readiness
/// - `sendAudio` feeds PCM into FluidAudio `SlidingWindowAsrManager`
/// - partials arrive as confirmed/volatile text grows (insert deltas only)
/// - `commitFinal` finishes the stream and emits remaining delta + done
/// - `clearBuffer` cancels the stream
final class ParakeetRealtimeClient: DictationRealtimeClient, @unchecked Sendable {
    private struct State: Sendable {
        var callbacks = RealtimeClient.Callbacks()
        var connectionState: RealtimeClient.ConnectionState = .disconnected
        var sessionID = UUID()
        var emittedText = ""
        var finalizing = false
        var generation: UInt64 = 0
        var utteranceStarted = false
    }

    private let engine: ParakeetEngine
    private let chunkSeconds: Double
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let feedQueue = OSAllocatedUnfairLock(initialState: Optional<Task<Void, Never>>.none)

    /// - Parameters:
    ///   - engine: Shared Parakeet TDT engine.
    ///   - chunkSeconds: Sliding-window center stride (mapped to FluidAudio chunkSeconds).
    init(engine: ParakeetEngine, chunkSeconds: Double = 1.5) {
        self.engine = engine
        self.chunkSeconds = chunkSeconds > 0 ? chunkSeconds : 1.5
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
            s.sessionID = UUID()
            s.emittedText = ""
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
            if ready {
                await self.engine.setPartialHandler { [weak self] full in
                    self?.handlePartialTranscript(full)
                }
                let cbs = self.state.withLock { s -> RealtimeClient.Callbacks in
                    s.connectionState = .connected
                    s.emittedText = ""
                    s.finalizing = false
                    s.utteranceStarted = false
                    return s.callbacks
                }
                cbs.onConnectionState?(.connected)
                AppLog.realtime.info(
                    "Parakeet TDT realtime client connected (sliding-window chunk=\(self.chunkSeconds, privacy: .public)s)"
                )
            } else {
                let cbs = self.state.withLock { s -> RealtimeClient.Callbacks in
                    s.connectionState = .disconnected
                    return s.callbacks
                }
                cbs.onConnectionState?(.disconnected)
                cbs.onError?("Parakeet models are not ready.")
                AppLog.realtime.error("Parakeet TDT connect failed — models not ready")
            }
        }
    }

    func disconnect() {
        cancelFeedWork()
        state.withLock { s in
            s.generation &+= 1
            s.utteranceStarted = false
            s.finalizing = false
            s.emittedText = ""
            s.sessionID = UUID()
            s.connectionState = .disconnected
        }
        Task { [weak self] in
            await self?.engine.setPartialHandler(nil)
            await self?.engine.cancelUtterance()
        }
        // onConnectionState disconnected once
        let cbs = state.withLock { $0.callbacks }
        cbs.onConnectionState?(.disconnected)
        AppLog.realtime.info("Parakeet TDT realtime client disconnected")
    }

    func sendAudio(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        let snapshot: (connected: Bool, finalizing: Bool, generation: UInt64) = state.withLock { s in
            (s.connectionState == .connected, s.finalizing, s.generation)
        }
        guard snapshot.connected, !snapshot.finalizing else { return }

        let previous = feedQueue.withLock { $0 }
        let generation = snapshot.generation
        let task = Task { [weak self] in
            if let previous {
                await previous.value
            }
            guard let self, !Task.isCancelled else { return }
            let still = self.state.withLock { s in
                s.connectionState == .connected && s.generation == generation
            }
            guard still else { return }

            // Start stream on first audio of this hold.
            let needStart = self.state.withLock { s -> Bool in
                if s.utteranceStarted { return false }
                s.utteranceStarted = true
                s.emittedText = ""
                return true
            }
            do {
                if needStart {
                    try await self.engine.beginUtterance()
                }
                try await self.engine.processAudio(pcm16: pcm16)
            } catch {
                if !Task.isCancelled {
                    AppLog.realtime.error(
                        "Parakeet TDT process failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        feedQueue.withLock { $0 = task }
    }

    @discardableResult
    func commitFinal() -> Bool {
        let snapshot: (connected: Bool, sessionID: UUID, emitted: String) = state.withLock { s in
            guard s.connectionState == .connected else {
                return (false, s.sessionID, s.emittedText)
            }
            s.finalizing = true
            return (true, s.sessionID, s.emittedText)
        }
        guard snapshot.connected else { return false }

        let previous = feedQueue.withLock { $0 }
        let task = Task { [weak self] in
            if let previous {
                let completed = await Self.awaitWithTimeout(previous, timeoutMs: 8_000)
                if !completed {
                    previous.cancel()
                    AppLog.realtime.error("Parakeet TDT feed drain timed out before commit")
                }
            }
            guard let self else { return }
            let generation = self.state.withLock { s -> UInt64 in
                s.generation &+= 1
                return s.generation
            }
            await Self.runCommit(
                client: self,
                engine: self.engine,
                sessionID: snapshot.sessionID,
                previouslyEmitted: snapshot.emitted,
                generation: generation
            )
        }
        feedQueue.withLock { $0 = task }
        return true
    }

    @discardableResult
    func clearBuffer() -> Bool {
        cancelFeedWork()
        let cbs = state.withLock { s -> RealtimeClient.Callbacks in
            s.emittedText = ""
            s.finalizing = false
            s.utteranceStarted = false
            s.generation &+= 1
            s.sessionID = UUID()
            return s.callbacks
        }
        Task { [weak self] in
            await self?.engine.cancelUtterance()
        }
        cbs.onBufferCleared?()
        return true
    }

    // MARK: - Partials

    private func handlePartialTranscript(_ full: String) {
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let snapshot = state.withLock { s -> (still: Bool, delta: String, callbacks: RealtimeClient.Callbacks) in
            guard s.connectionState == .connected, !s.finalizing else {
                return (false, "", s.callbacks)
            }
            let delta = Self.incrementalDelta(full: trimmed, previouslyEmitted: s.emittedText)
            if !delta.isEmpty {
                s.emittedText += delta
            }
            return (true, delta, s.callbacks)
        }
        guard snapshot.still, !snapshot.delta.isEmpty else { return }
        snapshot.callbacks.onDelta?(snapshot.delta, false)
        AppLog.realtime.info(
            "Parakeet TDT partial delta chars=\(snapshot.delta.count, privacy: .public) full=\(trimmed.count, privacy: .public)"
        )
    }

    private func cancelFeedWork() {
        feedQueue.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    private static func awaitWithTimeout(_ task: Task<Void, Never>, timeoutMs: UInt64) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            return finished
        }
    }

    private static func runCommit(
        client: ParakeetRealtimeClient?,
        engine: ParakeetEngine,
        sessionID: UUID,
        previouslyEmitted: String,
        generation: UInt64
    ) async {
        guard let client else { return }

        do {
            let text = try await engine.finishUtterance()
            let baseline = client.state.withLock { s -> String in
                guard s.sessionID == sessionID else { return previouslyEmitted }
                return s.emittedText
            }
            let delta = Self.incrementalDelta(full: text, previouslyEmitted: baseline)
            let snapshot = client.state.withLock { s -> (stillCurrent: Bool, callbacks: RealtimeClient.Callbacks) in
                let still = s.sessionID == sessionID && s.connectionState == .connected
                    && s.generation == generation
                if still {
                    s.emittedText = ""
                    s.finalizing = false
                    s.utteranceStarted = false
                    s.generation &+= 1
                }
                return (still, s.callbacks)
            }
            guard snapshot.stillCurrent else { return }

            if !delta.isEmpty {
                snapshot.callbacks.onDelta?(delta, false)
            }
            snapshot.callbacks.onDone?(text)
            AppLog.realtime.info(
                "Parakeet TDT commit complete — chars=\(text.count, privacy: .public) remainingDelta=\(delta.count, privacy: .public)"
            )
        } catch {
            let snapshot = client.state.withLock { s -> (stillCurrent: Bool, callbacks: RealtimeClient.Callbacks) in
                let still = s.sessionID == sessionID && s.connectionState == .connected
                if still {
                    s.emittedText = ""
                    s.finalizing = false
                    s.utteranceStarted = false
                    s.generation &+= 1
                }
                return (still, s.callbacks)
            }
            guard snapshot.stillCurrent else { return }
            AppLog.realtime.error(
                "Parakeet TDT commit failed: \(error.localizedDescription, privacy: .public)"
            )
            snapshot.callbacks.onError?(error.localizedDescription)
        }
    }

    static func incrementalDelta(full: String, previouslyEmitted: String) -> String {
        if previouslyEmitted.isEmpty {
            return full
        }
        if full.hasPrefix(previouslyEmitted) {
            return String(full.dropFirst(previouslyEmitted.count))
        }
        // Volatile revision — do not fight the insert path.
        return ""
    }
}
