import Foundation
import os

/// Persistent WebSocket client for the OpenAI Realtime subset spoken by the
/// local-dictation Python server.
final class RealtimeClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
    }

    struct Callbacks: Sendable {
        var onDelta: (@Sendable (String) -> Void)?
        var onDone: (@Sendable (String) -> Void)?
        var onConnectionState: (@Sendable (ConnectionState) -> Void)?
        var onError: (@Sendable (String) -> Void)?
        var onBufferCleared: (@Sendable () -> Void)?
    }

    private let endpoint: URL
    private let lock = NSLock()
    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var connectionState: ConnectionState = .disconnected
    private var callbacks = Callbacks()
    private var userInitiatedDisconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var shouldAutoReconnect = true

    private let maxReconnectBackoff: Double = 30

    init(endpoint: URL) {
        self.endpoint = endpoint
        super.init()
    }

    func setCallbacks(_ callbacks: Callbacks) {
        lock.lock()
        self.callbacks = callbacks
        lock.unlock()
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connectionState == .connected
    }

    func connect() {
        lock.lock()
        shouldAutoReconnect = true
        userInitiatedDisconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        lock.unlock()
        openSocket()
    }

    func disconnect() {
        lock.lock()
        shouldAutoReconnect = false
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        closeSocketLocked(cancelTask: true)
        let cbs = callbacks
        lock.unlock()
        cbs.onConnectionState?(.disconnected)
    }

    func sendAudio(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm16.base64EncodedString(),
        ]
        sendJSON(payload)
    }

    @discardableResult
    func commitFinal() -> Bool {
        sendJSON([
            "type": "input_audio_buffer.commit",
            "final": true,
        ])
    }

    @discardableResult
    func clearBuffer() -> Bool {
        sendJSON(["type": "input_audio_buffer.clear"])
    }

    // MARK: - Socket lifecycle

    private func openSocket() {
        lock.lock()
        closeSocketLocked(cancelTask: true)
        setConnectionStateLocked(.connecting)
        let cbs = callbacks

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 30
        let wsTask = session.webSocketTask(with: request)
        urlSession = session
        task = wsTask
        lock.unlock()

        cbs.onConnectionState?(.connecting)
        AppLog.realtime.info("Connecting to \(self.endpoint.absoluteString, privacy: .public)")
        wsTask.resume()
        listen(on: wsTask)
    }

    private func listen(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = self.task === task && self.connectionState == .connected
            self.lock.unlock()
            guard isCurrent else { return }

            switch result {
            case .success(let message):
                self.handle(message: message)
                self.listen(on: task)
            case .failure(let error):
                self.handleSocketFailure("WebSocket receive failed: \(error.localizedDescription)")
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let s):
            text = s
        case .data(let data):
            text = String(data: data, encoding: .utf8)
        @unknown default:
            text = nil
        }
        guard let text, let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return
        }

        lock.lock()
        let cbs = callbacks
        lock.unlock()

        switch type {
        case "response.audio_transcript.delta",
             "transcription.delta":
            if let delta = json["delta"] as? String ?? json["text"] as? String ?? json["transcript"] as? String {
                cbs.onDelta?(delta)
            }
        case "response.audio_transcript.done",
             "transcription.done":
            let transcript = (json["transcript"] as? String)
                ?? (json["text"] as? String)
                ?? (json["delta"] as? String)
                ?? ""
            cbs.onDone?(transcript)
        case "input_audio_buffer.cleared":
            cbs.onBufferCleared?()
        case "error":
            let message = (json["message"] as? String)
                ?? (json["error"] as? String)
                ?? "Unknown realtime error"
            cbs.onError?(message)
        default:
            break
        }
    }

    @discardableResult
    private func sendJSON(_ object: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else {
            return false
        }

        lock.lock()
        let currentTask = task
        let state = connectionState
        lock.unlock()

        guard state == .connected, let currentTask else {
            AppLog.realtime.debug("Dropping frame; not connected")
            return false
        }

        currentTask.send(.string(text)) { [weak self] error in
            if let error {
                self?.handleSocketFailure("WebSocket send failed: \(error.localizedDescription)")
            }
        }
        return true
    }

    private func handleSocketFailure(_ message: String) {
        lock.lock()
        let wasUser = userInitiatedDisconnect
        let shouldReconnect = shouldAutoReconnect && !wasUser
        closeSocketLocked(cancelTask: false)
        let cbs = callbacks
        let attempt = reconnectAttempt
        lock.unlock()

        if !wasUser {
            cbs.onError?(message)
        }
        cbs.onConnectionState?(.disconnected)

        guard shouldReconnect else { return }
        scheduleReconnect(attempt: attempt + 1)
    }

    private func scheduleReconnect(attempt: Int) {
        lock.lock()
        reconnectAttempt = attempt
        reconnectTask?.cancel()
        let backoff = min(maxReconnectBackoff, 0.5 * pow(2.0, Double(max(0, attempt - 1))))
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(backoff))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            // Hop off the async context before touching NSLock (Swift 6).
            DispatchQueue.global(qos: .utility).async {
                self.lock.lock()
                let allowed = self.shouldAutoReconnect
                self.lock.unlock()
                guard allowed else { return }
                AppLog.realtime.info("Reconnecting (attempt \(attempt)) after \(backoff)s")
                self.openSocket()
            }
        }
        lock.unlock()
    }

    private func setConnectionStateLocked(_ state: ConnectionState) {
        connectionState = state
    }

    private func closeSocketLocked(cancelTask: Bool) {
        if cancelTask {
            task?.cancel(with: .normalClosure, reason: nil)
        }
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        connectionState = .disconnected
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        guard task === webSocketTask else {
            lock.unlock()
            return
        }
        setConnectionStateLocked(.connected)
        reconnectAttempt = 0
        let cbs = callbacks
        lock.unlock()
        AppLog.realtime.info("WebSocket connected")
        cbs.onConnectionState?(.connected)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        lock.lock()
        guard task === webSocketTask else {
            lock.unlock()
            return
        }
        let wasUser = userInitiatedDisconnect
        let shouldReconnect = shouldAutoReconnect && !wasUser
        let attempt = reconnectAttempt
        closeSocketLocked(cancelTask: false)
        let cbs = callbacks
        lock.unlock()

        cbs.onConnectionState?(.disconnected)
        if shouldReconnect {
            scheduleReconnect(attempt: attempt + 1)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        lock.lock()
        let isOurs = self.task === task || (self.task == nil && urlSession === session)
        lock.unlock()
        guard isOurs else { return }
        handleSocketFailure("WebSocket completed with error: \(error.localizedDescription)")
    }
}
