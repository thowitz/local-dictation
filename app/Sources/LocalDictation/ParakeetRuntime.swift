import Foundation
import os

/// In-process speech runtime that loads Parakeet TDT 0.6B v3 CoreML models via
/// FluidAudio and serves sliding-window partials (`SlidingWindowAsrManager`).
///
/// Mirrors the `ServerSupervisor` lifecycle surface so `DictationController` can
/// treat Parakeet as a drop-in alternative provider (warm on launch, idle unload,
/// retry after failure). No Python process or WebSocket is involved.
@MainActor
final class ParakeetRuntime: SpeechRuntime {
    private(set) var state: ServerSupervisor.State = .idle {
        didSet {
            onStateChange?(state)
        }
    }

    var onStateChange: ((ServerSupervisor.State) -> Void)?

    private(set) var desiredRunning = false

    private let config: AppConfig
    private let engine: ParakeetEngine
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0

    init(config: AppConfig, engine: ParakeetEngine) {
        self.config = config
        self.engine = engine
    }

    func start() {
        desiredRunning = true
        if loadTask != nil {
            // Already loading — leave the current run alone.
            return
        }
        if case .running = state {
            return
        }
        beginLoad()
    }

    func retry() {
        stop(reason: .applicationQuit)
        start()
    }

    func stop(reason: ServerSupervisor.StopReason) {
        desiredRunning = false
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil

        let generation = loadGeneration
        Task { [engine] in
            await engine.unload()
        }
        // Ignore generation for unload fire-and-forget; loadGeneration already
        // invalidates any in-flight load that might re-publish `.running`.
        _ = generation

        switch reason {
        case .idleTimeout:
            transition(to: .stopped)
        case .applicationQuit:
            transition(to: .idle)
        }
    }

    // MARK: - Load

    private func beginLoad() {
        loadGeneration &+= 1
        let generation = loadGeneration
        transition(to: .launching)

        let modelPath = config.parakeetModelPath
        let directory = ParakeetEngine.resolveModelDirectory(explicitPath: modelPath)
        let willDownload = directory == nil
        let chunkSeconds = config.parakeetChunkSeconds

        if willDownload {
            transition(to: .downloading(percent: nil))
        } else {
            transition(to: .waitingForReady)
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.engine.setChunkSeconds(chunkSeconds)
                try await self.engine.load(directory: directory)
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                guard self.desiredRunning else {
                    await self.engine.unload()
                    self.finishLoad(generation: generation, state: .idle)
                    return
                }
                self.finishLoad(generation: generation, state: .running)
            } catch {
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                AppLog.general.error(
                    "Parakeet runtime load failed: \(error.localizedDescription, privacy: .public)"
                )
                let failure = ServerFailure(
                    kind: .launchFailed,
                    command: nil,
                    port: nil,
                    exit: ServerExit(
                        reason: .launchFailed(message: error.localizedDescription),
                        runDuration: .zero,
                        command: nil,
                        activity: .empty,
                        stderrTail: error.localizedDescription,
                        port: nil
                    ),
                    activity: .empty,
                    stderrTail: error.localizedDescription,
                    underlyingMessage: Self.remediationHint(for: error, modelPath: modelPath)
                )
                self.finishLoad(generation: generation, state: .failed(failure))
            }
        }
    }

    private func finishLoad(generation: UInt64, state: ServerSupervisor.State) {
        guard loadGeneration == generation else { return }
        loadTask = nil
        transition(to: state)
    }

    private func transition(to newState: ServerSupervisor.State) {
        guard state != newState else { return }
        state = newState
        AppLog.general.info(
            "parakeet runtime → \(String(describing: newState), privacy: .public)"
        )
    }

    private static func remediationHint(for error: Error, modelPath: String?) -> String {
        let pathHint: String
        if let modelPath, !modelPath.isEmpty {
            pathHint = "parakeetModelPath=\(modelPath)"
        } else {
            pathHint =
                "stage models at ~/\(SpeechProvider.parakeetDefaultRepoFolder) or set parakeetModelPath in config.json"
        }
        return """
        Parakeet TDT v3 (FluidAudio CoreML) failed to become ready.
        \(error.localizedDescription)
        Hint: \(pathHint). Stage FluidInference/parakeet-tdt-0.6b-v3-coreml or set parakeetModelPath. Provider is selected via "provider": "parakeet" in config.json.
        """
    }
}
