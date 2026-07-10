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
        case restarting(ServerRestartStatus)
        case stopped
        case failed(ServerFailure)
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

    /// Bounded stderr retained across attempts within one supervision run.
    private var stderrCollector = BoundedStderrCollector()
    private var activity = StartupActivitySnapshot.empty
    private var currentCommand: ServerLaunchCommand?
    private var attemptStartedAt: Date?
    private var attemptNumber = 0

    private let maxConsecutiveFailures = 5
    private let readinessPollInterval: Duration = .milliseconds(400)
    private let readinessTimeout: Duration = .seconds(600)

    init(config: AppConfig) {
        self.config = config
    }

    func start() {
        guard supervisionTask == nil else { return }
        stoppingIntentionally = false
        // Clear the collector only at the start of a NEW supervision run.
        stderrCollector.reset()
        activity = .empty
        currentCommand = nil
        attemptNumber = 0
        transition(to: .launching)
        supervisionTask = Task { @MainActor [weak self] in
            await self?.supervise()
        }
    }

    /// Restart after a terminal `.failed` without requiring a full app relaunch.
    func retry() {
        stop()
        start()
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

        if !(1...65535).contains(config.port) {
            transition(to: .failed(makeFailure(
                kind: .invalidPort,
                message: "Invalid port \(config.port); expected 1...65535."
            )))
            return
        }

        if await probeHealth() {
            transition(to: .failed(makeFailure(
                kind: .portInUse,
                message: "Port \(config.port) already in use; refusing to adopt an existing process."
            )))
            return
        }

        var consecutiveFailures = 0
        var latestExit: ServerExit?

        while !stoppingIntentionally && !Task.isCancelled {
            transition(to: .launching)
            downloadPercent = nil
            sawReadyMarker = false
            attemptNumber += 1
            stderrCollector.beginAttempt(attemptNumber)
            attemptStartedAt = Date()

            do {
                try spawn()
            } catch {
                let failure = failureFromSpawnError(error)
                transition(to: .failed(failure))
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
                latestExit = makeExit(reason: exitReasonFromProcess())

            case .exited:
                guard !stoppingIntentionally && !Task.isCancelled else { return }
                consecutiveFailures += 1
                latestExit = makeExit(reason: exitReasonFromProcess())

            case .timedOut:
                if let process, process.isRunning {
                    process.terminate()
                }
                flushStderrEOF()
                clearProcess()
                transition(to: .failed(makeFailure(
                    kind: .readinessTimedOut,
                    message: "Server did not become ready before timeout.",
                    exit: makeExit(reason: .timedOut)
                )))
                return

            case .cancelled:
                return
            }

            flushStderrEOF()
            clearProcess()

            if consecutiveFailures >= maxConsecutiveFailures {
                let exit = latestExit ?? makeExit(reason: .unknown)
                transition(to: .failed(makeFailure(
                    kind: .consecutiveExits,
                    message: "Server exited \(consecutiveFailures) consecutive times.",
                    exit: exit
                )))
                return
            }

            let backoffSeconds = min(30.0, 0.5 * pow(2.0, Double(max(0, consecutiveFailures - 1))))
            let backoff = Duration.seconds(backoffSeconds)
            let exit = latestExit ?? makeExit(reason: .unknown)
            let status = ServerRestartStatus(
                attempt: consecutiveFailures,
                maxAttempts: maxConsecutiveFailures,
                backoff: backoff,
                latestExit: exit
            )
            transition(to: .restarting(status))
            do {
                try await Task.sleep(for: backoff)
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

        let resolution = config.resolveServerLaunchCommand()
        let command: ServerLaunchCommand
        switch resolution {
        case .success(let resolved):
            command = resolved
        case .failure(let error):
            throw SpawnResolutionError(error)
        }

        currentCommand = command

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.processArguments(
            port: config.port,
            parentPID: ProcessInfo.processInfo.processIdentifier,
            model: config.model
        )

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stdoutPipe = stdout
        stderrPipe = stderr

        attachReader(to: stdout, isStderr: false)
        attachReader(to: stderr, isStderr: true)

        do {
            try process.run()
        } catch {
            throw SpawnLaunchError(underlying: error, command: command)
        }
        self.process = process
        AppLog.server.info(
            "Launched server source=\(command.source.rawValue, privacy: .public) pid=\(process.processIdentifier) cmd=\(command.displayCommandLine, privacy: .public)"
        )
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
        if isStderr {
            stderrCollector.append(data: data)
        }

        // Preserve undecoded bytes for the collector; decode lossily for line handling.
        let text = String(decoding: data, as: UTF8.self)
        if DownloadProgressParser.isStartupActivity(text) {
            activity.lastOutputAt = Date()
        }

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
            noteDownloadProgress(in: buffer)
        }
    }

    private func handleLine(_ raw: String, isStderr: Bool) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        if isStderr {
            AppLog.server.debug("[stderr] \(line, privacy: .public)")
            noteDownloadProgress(in: line)
        } else {
            AppLog.server.info("[stdout] \(line, privacy: .public)")
            if line.hasPrefix("VOXMLX_READY") {
                sawReadyMarker = true
            }
        }
    }

    private func noteDownloadProgress(in line: String) {
        let parsed = DownloadProgressParser.parse(line)
        guard parsed.isDownloadProgress else { return }

        activity.lastDownloadProgressAt = Date()
        activity.lastOutputAt = Date()
        if let percent = parsed.percent {
            activity.downloadPercent = percent
            activity.downloadPercentUnknown = false
            downloadPercent = percent
        } else if parsed.percentUnknown {
            activity.downloadPercentUnknown = true
            downloadPercent = nil
        }

        // Only surface downloading while we're still waiting for readiness.
        switch state {
        case .waitingForReady, .launching, .downloading:
            transition(to: .downloading(percent: downloadPercent))
        default:
            break
        }
    }

    private func flushStderrEOF() {
        stderrCollector.flushEOF()
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
        // Intentionally do NOT reset stderrCollector here — retain across attempts.
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

    // MARK: - Failure / exit mapping

    private func makeExit(reason: ServerExit.Reason) -> ServerExit {
        let started = attemptStartedAt ?? Date()
        let duration = Date().timeIntervalSince(started)
        return ServerExit(
            reason: reason,
            runDuration: .seconds(duration),
            command: currentCommand,
            activity: activity,
            stderrTail: stderrCollector.tail(),
            port: config.port
        )
    }

    private func exitReasonFromProcess() -> ServerExit.Reason {
        guard let process else { return .unknown }
        if process.terminationReason == .uncaughtSignal {
            return .signaled(signal: process.terminationStatus)
        }
        return .exited(status: process.terminationStatus)
    }

    private func makeFailure(
        kind: ServerFailure.Kind,
        message: String?,
        exit: ServerExit? = nil
    ) -> ServerFailure {
        ServerFailure(
            kind: kind,
            command: currentCommand ?? exit?.command,
            port: config.port,
            exit: exit,
            activity: exit?.activity ?? activity,
            stderrTail: exit?.stderrTail ?? stderrCollector.tail(),
            underlyingMessage: message
        )
    }

    private func failureFromSpawnError(_ error: Error) -> ServerFailure {
        if let resolution = error as? SpawnResolutionError {
            switch resolution.error {
            case .overrideMissing, .noCandidateFound:
                return makeFailure(kind: .commandNotFound, message: resolution.error.description)
            case .overrideNotExecutable:
                return makeFailure(kind: .commandNotExecutable, message: resolution.error.description)
            case .overrideNotAbsolute:
                return makeFailure(kind: .commandNotFound, message: resolution.error.description)
            }
        }
        if let launch = error as? SpawnLaunchError {
            currentCommand = launch.command
            return makeFailure(
                kind: .launchFailed,
                message: launch.underlying.localizedDescription,
                exit: makeExit(reason: .launchFailed(message: launch.underlying.localizedDescription))
            )
        }
        return makeFailure(kind: .launchFailed, message: error.localizedDescription)
    }
}

/// Wraps a resolver failure so `spawn()` can map it to `ServerFailure.Kind`.
private struct SpawnResolutionError: Error {
    let error: ServerLaunchCommandResolver.ResolutionError
    init(_ error: ServerLaunchCommandResolver.ResolutionError) { self.error = error }
}

private struct SpawnLaunchError: Error {
    let underlying: Error
    let command: ServerLaunchCommand
}
