import Darwin
import Foundation
import os

/// Spawns and supervises the Python realtime server process.
@MainActor
final class ServerSupervisor {
    enum State: Equatable, Sendable {
        case idle
        case launching
        case downloading(percent: Int?)
        case waitingForReady
        case running
        case restarting(attempt: Int)
        case stopped
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet {
            onStateChange?(state)
        }
    }

    var onStateChange: ((State) -> Void)?

    private let config: AppConfig
    private var process: Process?
    private var supervisionTask: Task<Void, Never>?
    private var stoppingIntentionally = false
    private var stdoutPartial = ""
    private var stderrPartial = ""
    private var sawReadyMarker = false
    private var downloadPercent: Int?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private let maxConsecutiveFailures = 5
    private let readinessPollInterval: Duration = .milliseconds(400)
    private let readinessTimeout: Duration = .seconds(600)

    init(config: AppConfig) {
        self.config = config
    }

    func start() {
        guard supervisionTask == nil else { return }
        stoppingIntentionally = false
        transition(to: .launching)
        supervisionTask = Task { @MainActor [weak self] in
            await self?.supervise()
        }
    }

    func stop() {
        stoppingIntentionally = true
        supervisionTask?.cancel()
        if let process, process.isRunning {
            process.terminate()
        }
        clearProcess()
        supervisionTask = nil
        transition(to: .stopped)
    }

    // MARK: - Supervision loop

    private func supervise() async {
        defer { supervisionTask = nil }

        if await probeHealth() {
            transition(to: .failed("Port \(config.port) already in use; refusing to adopt an existing process."))
            return
        }

        var consecutiveFailures = 0

        while !stoppingIntentionally && !Task.isCancelled {
            transition(to: .launching)
            downloadPercent = nil
            sawReadyMarker = false

            do {
                try spawn()
            } catch {
                transition(to: .failed("Failed to launch server: \(error.localizedDescription)"))
                return
            }

            transition(to: .waitingForReady)
            let outcome = await waitForReadiness()

            switch outcome {
            case .ready:
                consecutiveFailures = 0
                transition(to: .running)
                await waitForExit()
                guard !stoppingIntentionally && !Task.isCancelled else { return }
                consecutiveFailures += 1

            case .exited:
                guard !stoppingIntentionally && !Task.isCancelled else { return }
                consecutiveFailures += 1

            case .timedOut:
                if let process, process.isRunning {
                    process.terminate()
                }
                clearProcess()
                transition(to: .failed("Server did not become ready before timeout."))
                return

            case .cancelled:
                return
            }

            clearProcess()

            if consecutiveFailures >= maxConsecutiveFailures {
                transition(to: .failed("Server exited \(consecutiveFailures) consecutive times."))
                return
            }

            transition(to: .restarting(attempt: consecutiveFailures))
            let backoff = min(30.0, 0.5 * pow(2.0, Double(max(0, consecutiveFailures - 1))))
            do {
                try await Task.sleep(for: .seconds(backoff))
            } catch {
                return
            }
        }
    }

    private enum ReadinessOutcome {
        case ready
        case exited
        case timedOut
        case cancelled
    }

    private func waitForReadiness() async -> ReadinessOutcome {
        var elapsed: Duration = .zero

        while !stoppingIntentionally && !Task.isCancelled {
            if process?.isRunning != true {
                return .exited
            }

            if sawReadyMarker {
                return .ready
            }
            if await probeHealth() {
                return .ready
            }

            do {
                try await Task.sleep(for: readinessPollInterval)
            } catch {
                return .cancelled
            }

            elapsed += readinessPollInterval
            if process?.isRunning != true {
                return .exited
            }
            if elapsed >= readinessTimeout {
                return .timedOut
            }
        }
        return .cancelled
    }

    private func waitForExit() async {
        guard let process else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !process.isRunning {
                continuation.resume()
                return
            }
            let existing = process.terminationHandler
            process.terminationHandler = { proc in
                existing?(proc)
                continuation.resume()
            }
        }
    }

    // MARK: - Process

    private func spawn() throws {
        clearProcess()

        let executable = config.resolvedServerExecutable
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(
                domain: "LocalDictation.ServerSupervisor",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Server executable not found at \(executable.path). Run `uv sync` in server/ or set serverExecutable in config.json.",
                ]
            )
        }

        let process = Process()
        process.executableURL = executable
        var args = [
            "--port", "\(config.port)",
            "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)",
        ]
        if let model = config.model, !model.isEmpty {
            args += ["--model", model]
        }
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stdoutPipe = stdout
        stderrPipe = stderr

        attachReader(to: stdout, isStderr: false)
        attachReader(to: stderr, isStderr: true)

        try process.run()
        self.process = process
        AppLog.server.info("Launched server pid=\(process.processIdentifier)")
    }

    private func attachReader(to pipe: Pipe, isStderr: Bool) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                self?.appendOutput(data: data, isStderr: isStderr)
            }
        }
    }

    private func appendOutput(data: Data, isStderr: Bool) {
        let text = String(decoding: data, as: UTF8.self)
        var buffer = (isStderr ? stderrPartial : stdoutPartial) + text
        let endsWithNewline = buffer.hasSuffix("\n") || buffer.hasSuffix("\r")
        // tqdm rewrites the same line with \r — split on both.
        var pieces = buffer.components(separatedBy: CharacterSet(charactersIn: "\n\r"))

        if endsWithNewline {
            buffer = ""
            if pieces.last?.isEmpty == true {
                pieces.removeLast()
            }
        } else {
            buffer = pieces.popLast() ?? ""
        }

        if isStderr {
            stderrPartial = buffer
        } else {
            stdoutPartial = buffer
        }

        for piece in pieces {
            handleLine(piece, isStderr: isStderr)
        }
        // Also inspect the in-progress (no newline yet) buffer for tqdm % updates.
        if isStderr, !buffer.isEmpty {
            parseDownloadProgress(in: buffer)
        }
    }

    private func handleLine(_ raw: String, isStderr: Bool) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        if isStderr {
            AppLog.server.debug("[stderr] \(line, privacy: .public)")
            parseDownloadProgress(in: line)
        } else {
            AppLog.server.info("[stdout] \(line, privacy: .public)")
            if line.hasPrefix("VOXMLX_READY") {
                sawReadyMarker = true
            }
        }
    }

    /// Parses huggingface-hub / tqdm progress lines like
    /// `model.safetensors:  45%|████| 1.57G/3.50G [...]` or `Fetching 12 files:  30%|...`.
    private func parseDownloadProgress(in line: String) {
        guard let percent = Self.extractPercent(from: line) else { return }
        downloadPercent = percent
        // Only surface downloading while we're still waiting for readiness.
        switch state {
        case .waitingForReady, .launching, .downloading:
            transition(to: .downloading(percent: percent))
        default:
            break
        }
    }

    static func extractPercent(from line: String) -> Int? {
        // Match the first `NN%` or `NN.N%` token.
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,3})(?:\.\d+)?%"#) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let percentRange = Range(match.range(at: 1), in: line),
              let value = Int(line[percentRange])
        else {
            return nil
        }
        return min(100, max(0, value))
    }

    private func clearProcess() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutPartial = ""
        stderrPartial = ""
        process = nil
        sawReadyMarker = false
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        AppLog.server.info("state → \(String(describing: newState), privacy: .public)")
    }

    private func probeHealth() async -> Bool {
        var request = URLRequest(url: config.healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
