import Foundation

/// Shared lifecycle surface for the speech runtime, whether it is the Python
/// Voxtral process (`ServerSupervisor`) or the in-process Parakeet CoreML path.
///
/// State cases intentionally reuse `ServerSupervisor.State` so the dictation
/// controller and menu presentation stay provider-agnostic.
@MainActor
protocol SpeechRuntime: AnyObject {
    var state: ServerSupervisor.State { get }
    var desiredRunning: Bool { get }
    var onStateChange: ((ServerSupervisor.State) -> Void)? { get set }

    func start()
    func stop(reason: ServerSupervisor.StopReason)
    func retry()
}

extension ServerSupervisor: SpeechRuntime {}
