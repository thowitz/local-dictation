import Foundation

/// Narrow realtime seam so lifecycle tests can inject a fake without URLSession.
protocol DictationRealtimeClient: AnyObject {
    var isConnected: Bool { get }
    func setCallbacks(_ callbacks: RealtimeClient.Callbacks)
    func connect()
    func disconnect()
    func sendAudio(_ pcm16: Data)
    @discardableResult func commitFinal() -> Bool
    @discardableResult func clearBuffer() -> Bool
}

extension RealtimeClient: DictationRealtimeClient {}
