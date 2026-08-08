import Foundation

/// Which speech-recognition backend powers the speech runtime.
enum SpeechProvider: String, Codable, Sendable, CaseIterable {
    /// Default: Python WebSocket server with MLX Voxtral realtime.
    case voxtral
    /// In-process FluidAudio Parakeet TDT 0.6B v3 CoreML (batch on finalize).
    case parakeet

    var displayName: String {
        switch self {
        case .voxtral: return "Voxtral (MLX)"
        case .parakeet: return "Parakeet TDT v3 (CoreML)"
        }
    }

    /// Hugging Face clone folder name (common user staging path).
    static let parakeetDefaultRepoFolder = "parakeet-tdt-0.6b-v3-coreml"
}
