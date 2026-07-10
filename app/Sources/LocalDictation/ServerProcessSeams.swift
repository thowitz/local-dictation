import Darwin
import Foundation

// MARK: - Policy

/// Injectable timing / retry constants for `ServerSupervisor`.
struct ServerSupervisorPolicy: Sendable {
    var maxConsecutiveFailures: Int
    var readinessPollInterval: Duration
    /// Refreshed by any non-empty output / recognized download progress.
    var inactivityTimeout: Duration
    /// Absolute startup deadline before any download activity is observed.
    var absoluteStartupCap: Duration
    /// Absolute startup deadline once download activity has been observed (~2h).
    var downloadActiveStartupCap: Duration
    var terminationGrace: Duration
    var healthyStabilityWindow: Duration
    var backoffBaseSeconds: Double
    var backoffCapSeconds: Double
    /// Bound on awaiting stdout/stderr EOF after exit/timeout (inherited FDs).
    var outputDrainTimeout: Duration

    static let production = ServerSupervisorPolicy(
        maxConsecutiveFailures: 5,
        readinessPollInterval: .milliseconds(400),
        inactivityTimeout: .seconds(600),
        absoluteStartupCap: .seconds(60 * 60),
        downloadActiveStartupCap: .seconds(2 * 60 * 60),
        terminationGrace: .seconds(2),
        healthyStabilityWindow: .seconds(60),
        backoffBaseSeconds: 0.5,
        backoffCapSeconds: 30,
        outputDrainTimeout: .seconds(2)
    )

    func backoff(forAttempt attempt: Int) -> Duration {
        let seconds = min(
            backoffCapSeconds,
            backoffBaseSeconds * pow(2.0, Double(max(0, attempt - 1)))
        )
        return .seconds(seconds)
    }
}

// MARK: - Port probe

enum PortProbeResult: Equatable, Sendable {
    case available
    case inUse
    case unavailable
}

enum PortProbe {
    /// Loopback TCP bind with `SO_REUSEADDR` (never `SO_REUSEPORT`).
    static func bind(host: String = "127.0.0.1", port: Int) -> PortProbeResult {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return .unavailable }
        defer { close(fd) }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr(host))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult == 0 {
            return .available
        }
        let err = errno
        if err == EADDRINUSE {
            return .inUse
        }
        return .unavailable
    }
}

// MARK: - Managed process

enum ManagedProcessExit: Equatable, Sendable {
    case exited(status: Int32)
    case signaled(signal: Int32)
}

/// Abstraction over a child process so the supervisor loop is testable.
@MainActor
protocol ManagedProcess: AnyObject {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    var exit: ManagedProcessExit? { get }

    var onStdout: ((Data) -> Void)? { get set }
    var onStderr: ((Data) -> Void)? { get set }
    /// Must be installed before `launch()`.
    var onTerminate: (() -> Void)? { get set }

    func launch() throws
    func terminate()
    func forceKill()
    /// Await stdout/stderr EOF. Must be cancellation-aware (unblocks on Task cancel).
    func waitForOutputEOF() async
    /// Detach pipe readers, force EOF flags, and resume any parked EOF waiters.
    func forceFinishOutputDrain()
    /// True once both stdout and stderr have reached EOF (or been force-finished).
    var hasReachedOutputEOF: Bool { get }
}

/// Production wrapper around `Foundation.Process` + pipes.
@MainActor
final class FoundationManagedProcess: ManagedProcess {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutEOF = false
    private var stderrEOF = false
    private var eofContinuations: [CheckedContinuation<Void, any Error>] = []
    private var didLaunch = false

    var onStdout: ((Data) -> Void)?
    var onStderr: ((Data) -> Void)?
    var onTerminate: (() -> Void)?

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    var hasReachedOutputEOF: Bool { stdoutEOF && stderrEOF }

    /// Read termination facts from Foundation when the process has stopped —
    /// do not rely on a MainActor Task publishing a stored var (race).
    var exit: ManagedProcessExit? {
        guard didLaunch, !process.isRunning else { return nil }
        if process.terminationReason == .uncaughtSignal {
            return .signaled(signal: process.terminationStatus)
        }
        return .exited(status: process.terminationStatus)
    }

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func launch() throws {
        // Install termination observation BEFORE run() — no check-then-handler gap.
        let existing = process.terminationHandler
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.onTerminate?()
                existing?(proc)
            }
        }

        attachReader(stdoutPipe, isStderr: false)
        attachReader(stderrPipe, isStderr: true)

        try process.run()
        didLaunch = true
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func forceKill() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    func waitForOutputEOF() async {
        if stdoutEOF && stderrEOF { return }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                    if self.stdoutEOF && self.stderrEOF {
                        cont.resume()
                    } else {
                        self.eofContinuations.append(cont)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.failEOFWaiters(CancellationError())
                }
            }
        } catch {
            // Cancelled or forced finish — caller treats as drain complete.
        }
    }

    func forceFinishOutputDrain() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutEOF = true
        stderrEOF = true
        resumeEOFIfNeeded()
    }

    private func attachReader(_ pipe: Pipe, isStderr: Bool) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self else { return }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if isStderr {
                        self.stderrEOF = true
                    } else {
                        self.stdoutEOF = true
                    }
                    self.resumeEOFIfNeeded()
                    return
                }
                if isStderr {
                    self.onStderr?(data)
                } else {
                    self.onStdout?(data)
                }
            }
        }
    }

    private func resumeEOFIfNeeded() {
        guard stdoutEOF && stderrEOF else { return }
        let pending = eofContinuations
        eofContinuations.removeAll()
        for cont in pending {
            cont.resume()
        }
    }

    private func failEOFWaiters(_ error: Error) {
        let pending = eofContinuations
        eofContinuations.removeAll()
        for cont in pending {
            cont.resume(throwing: error)
        }
    }
}

typealias ManagedProcessFactory = @MainActor (
    _ executableURL: URL,
    _ arguments: [String]
) -> any ManagedProcess
