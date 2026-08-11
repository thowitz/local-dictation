import Foundation

/// Which speech-recognition backend powers the speech runtime.
enum SpeechProvider: String, Codable, Sendable, CaseIterable {
    /// Python WebSocket server with MLX Voxtral realtime.
    case voxtral
    /// In-process FluidAudio Parakeet TDT 0.6B v3 CoreML (sliding-window partials).
    case parakeet
    /// Python WebSocket server with parakeet-mlx (true streaming partials).
    case parakeetMlx = "parakeet-mlx"

    var displayName: String {
        switch self {
        case .voxtral: return "Voxtral (MLX)"
        case .parakeet: return "Parakeet TDT v3 (CoreML)"
        case .parakeetMlx: return "Parakeet TDT v3 (MLX)"
        }
    }

    /// True when the app launches the Python speech server.
    var usesPythonServer: Bool {
        switch self {
        case .voxtral, .parakeetMlx: return true
        case .parakeet: return false
        }
    }

    /// Hugging Face clone folder name for Parakeet TDT v3 CoreML models.
    static let parakeetDefaultRepoFolder = "parakeet-tdt-0.6b-v3-coreml"

    /// Common clone folder name for mlx-community Parakeet TDT weights (no `-coreml`).
    static let parakeetMlxDefaultRepoFolder = "parakeet-tdt-0.6b-v3"

    /// Default HF id for the MLX Parakeet weights.
    static let parakeetMlxDefaultModel = "mlx-community/parakeet-tdt-0.6b-v3"
}
