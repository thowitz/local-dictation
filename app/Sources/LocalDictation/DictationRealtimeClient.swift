import Foundation

/// Narrow realtime seam so lifecycle tests can inject a fake without URLSession.
///
/// `Sendable`: `sendAudio` is called directly from the audio capture thread so
/// audio stays ordered with `commitFinal` (see `AudioGate`).
protocol DictationRealtimeClient: AnyObject, Sendable {
    var isConnected: Bool { get }
    func setCallbacks(_ callbacks: RealtimeClient.Callbacks)
    func connect()
    func disconnect()
    func sendAudio(_ pcm16: Data)
    @discardableResult func commitFinal() -> Bool
    @discardableResult func clearBuffer() -> Bool
}

extension RealtimeClient: DictationRealtimeClient {}

/// Forwards captured audio to the realtime client while a session is open.
///
/// Audio is forwarded synchronously on the capture thread. `close()` waits for
/// an in-flight forward, so once it returns no more audio can reach the
/// client — `commitFinal` sent afterwards is guaranteed to follow every chunk,
/// and a stale chunk can never leak into the next utterance.
final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (Data) -> Void)?

    func open(_ sink: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    func close() {
        lock.lock()
        sink = nil
        lock.unlock()
    }

    func forward(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        sink?(chunk)
    }
}
