import Foundation

// MARK: - Startup / download activity

/// Snapshot of the most recent startup-related activity observed from the child.
struct StartupActivitySnapshot: Equatable, Sendable {
    /// Wall-clock time of the last non-empty stdout/stderr (or recognized progress).
    var lastOutputAt: Date?
    /// Last recognized Hugging Face / tqdm percent, if any.
    var downloadPercent: Int?
    /// True when the last recognized progress line had an unknown percent.
    var downloadPercentUnknown: Bool
    /// Wall-clock time of the last recognized download-progress line.
    var lastDownloadProgressAt: Date?

    static let empty = StartupActivitySnapshot(
        lastOutputAt: nil,
        downloadPercent: nil,
        downloadPercentUnknown: false,
        lastDownloadProgressAt: nil
    )

    var hasDownloadActivity: Bool {
        downloadPercent != nil || downloadPercentUnknown || lastDownloadProgressAt != nil
    }
}

// MARK: - Server exit / restart / failure

/// Facts about a single child-process exit (or timeout treated as an exit).
struct ServerExit: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case exited(status: Int32)
        case signaled(signal: Int32)
        case timedOut
        case launchFailed(message: String)
        case unknown
    }

    var reason: Reason
    var runDuration: Duration
    var command: ServerLaunchCommand?
    var activity: StartupActivitySnapshot
    var stderrTail: String
    var port: Int?

    var statusCode: Int32? {
        if case .exited(let status) = reason { return status }
        return nil
    }

    var signal: Int32? {
        if case .signaled(let signal) = reason { return signal }
        return nil
    }
}

/// In-progress restart budget surfaced to the menu.
struct ServerRestartStatus: Equatable, Sendable {
    var attempt: Int
    var maxAttempts: Int
    var backoff: Duration
    var latestExit: ServerExit

    var menuSummary: String {
        let seconds = backoffSecondsLabel
        return "Restarting \(attempt)/\(maxAttempts) in \(seconds)…"
    }

    private var backoffSecondsLabel: String {
        let seconds = Double(backoff.components.seconds)
            + Double(backoff.components.attoseconds) / 1e18
        if seconds < 1 {
            return String(format: "%.1fs", seconds)
        }
        if seconds == floor(seconds) {
            return "\(Int(seconds))s"
        }
        return String(format: "%.1fs", seconds)
    }
}

/// Terminal or presentable server failure.
struct ServerFailure: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable, CaseIterable {
        case commandNotFound
        case commandNotExecutable
        case launchFailed
        case invalidPort
        case portInUse
        case portUnavailable
        case readinessTimedOut
        case consecutiveExits
    }

    var kind: Kind
    var command: ServerLaunchCommand?
    var port: Int?
    var exit: ServerExit?
    var activity: StartupActivitySnapshot
    var stderrTail: String
    var underlyingMessage: String?

    /// Concise menu-row / status-title summary (no long diagnostics).
    var menuSummary: String {
        switch kind {
        case .commandNotFound:
            return "Server command not found"
        case .commandNotExecutable:
            return "Server command not executable"
        case .launchFailed:
            return "Server launch failed"
        case .invalidPort:
            return "Invalid server port"
        case .portInUse:
            return "Server port in use"
        case .portUnavailable:
            return "Server port unavailable"
        case .readinessTimedOut:
            return "Server readiness timed out"
        case .consecutiveExits:
            return "Server exited repeatedly"
        }
    }

    /// Known next step, or nil when we should only show facts/tail.
    var remediation: String? {
        ServerRemediation.classify(failure: self)
    }

    /// Multi-line details for the native alert / clipboard.
    var detailsText: String {
        ServerFailureDetails.format(self)
    }
}

// MARK: - Remediation

enum ServerRemediation {
    static func classify(failure: ServerFailure) -> String? {
        classify(
            kind: failure.kind,
            commandSource: failure.command?.source,
            stderrTail: failure.stderrTail,
            underlyingMessage: failure.underlyingMessage
        )
    }

    static func classify(
        kind: ServerFailure.Kind,
        commandSource: ServerLaunchCommandSource?,
        stderrTail: String,
        underlyingMessage: String? = nil
    ) -> String? {
        let haystack = ((underlyingMessage ?? "") + "\n" + stderrTail).lowercased()

        switch kind {
        case .portInUse, .portUnavailable:
            return "Stop the other process using this port, or change `port` in config.json and relaunch."
        case .invalidPort:
            return "Set `port` in config.json to an integer in 1…65535 and relaunch."
        case .commandNotFound, .commandNotExecutable:
            return remediationForMissingCommand(source: commandSource)
        case .launchFailed, .readinessTimedOut, .consecutiveExits:
            if looksLikePortCollision(haystack) {
                return "Stop the other process using this port, or change `port` in config.json and relaunch."
            }
            if looksLikeImportFailure(haystack) {
                return remediationForImport(source: commandSource)
            }
            if looksLikeModelOrNetworkFailure(haystack) {
                return "Check network and disk space, run `make model` in development, then Retry Server."
            }
            return nil
        }
    }

    private static func remediationForMissingCommand(source: ServerLaunchCommandSource?) -> String {
        switch source {
        case .bundleHelper:
            return "Reinstall the Local Dictation app (packaged helper is missing or not executable)."
        case .development, .applicationSupport, .override, .none:
            return "Run `make server` / `uv sync` in server/, or set an absolute `serverExecutable` in config.json."
        }
    }

    private static func remediationForImport(source: ServerLaunchCommandSource?) -> String {
        switch source {
        case .bundleHelper:
            return "Reinstall the Local Dictation app (packaged Python module failed to import)."
        default:
            return "Run `make server` / `uv sync` in server/, then Retry Server."
        }
    }

    private static func looksLikePortCollision(_ haystack: String) -> Bool {
        haystack.contains("port_in_use")
            || haystack.contains("eaddrinuse")
            || haystack.contains("address already in use")
    }

    private static func looksLikeImportFailure(_ haystack: String) -> Bool {
        haystack.contains("modulenotfounderror")
            || haystack.contains("no module named")
            || haystack.contains("importerror")
            || haystack.contains("failed to import")
    }

    private static func looksLikeModelOrNetworkFailure(_ haystack: String) -> Bool {
        haystack.contains("huggingface")
            || haystack.contains("hf_hub")
            || haystack.contains("connection error")
            || haystack.contains("connectionerror")
            || haystack.contains("timed out")
            || haystack.contains("timeout")
            || haystack.contains("no space left")
            || haystack.contains("disk quota")
            || haystack.contains("oserror") && haystack.contains("errno 28")
    }
}

enum ServerFailureDetails {
    static func format(_ failure: ServerFailure) -> String {
        var lines: [String] = []
        lines.append("summary: \(failure.menuSummary)")
        lines.append("kind: \(failure.kind.rawValue)")
        if let remediation = failure.remediation {
            lines.append("next step: \(remediation)")
        }
        if let command = failure.command {
            lines.append(contentsOf: command.detailDescription.split(separator: "\n").map(String.init))
            lines.append("invocation: \(command.displayCommandLine)")
        } else {
            lines.append("command: (none)")
        }
        if let port = failure.port {
            lines.append("port: \(port)")
        }
        if let message = failure.underlyingMessage, !message.isEmpty {
            lines.append("message: \(message)")
        }
        appendActivity(&lines, failure.activity)
        if let exit = failure.exit {
            appendExit(&lines, exit)
        }
        let tail = failure.stderrTail
        if tail.isEmpty {
            lines.append("stderr: (empty)")
        } else {
            lines.append("stderr:")
            lines.append(tail)
        }
        return lines.joined(separator: "\n")
    }

    private static func appendActivity(_ lines: inout [String], _ activity: StartupActivitySnapshot) {
        if let percent = activity.downloadPercent {
            lines.append("download progress: \(percent)%")
        } else if activity.downloadPercentUnknown {
            lines.append("download progress: (unknown %)")
        }
        if let at = activity.lastDownloadProgressAt {
            lines.append("last download activity: \(ISO8601DateFormatter().string(from: at))")
        }
        if let at = activity.lastOutputAt {
            lines.append("last startup output: \(ISO8601DateFormatter().string(from: at))")
        }
    }

    private static func appendExit(_ lines: inout [String], _ exit: ServerExit) {
        switch exit.reason {
        case .exited(let status):
            lines.append("exit status: \(status)")
        case .signaled(let signal):
            lines.append("exit signal: \(signal)")
        case .timedOut:
            lines.append("exit reason: readiness timed out")
        case .launchFailed(let message):
            lines.append("exit reason: launch failed (\(message))")
        case .unknown:
            lines.append("exit reason: unknown")
        }
        let seconds = Double(exit.runDuration.components.seconds)
            + Double(exit.runDuration.components.attoseconds) / 1e18
        lines.append(String(format: "run duration: %.1fs", seconds))
    }
}

// MARK: - Bounded stderr collector

/// In-memory 8 KiB / 50-logical-line stderr tail for one supervision run.
struct BoundedStderrCollector: Equatable, Sendable {
    static let maxBytes = 8 * 1024
    static let maxLines = 50
    static let truncationMarker = "…[truncated]…"
    static let attemptSeparatorPrefix = "——— attempt "

    private var lines: [String] = []
    private var pendingUTF8 = Data()
    private var pendingLine = ""
    /// Cached UTF-8 byte length of `pendingLine` (avoid O(n) `.utf8.count` on the hot path).
    private var pendingLineUTF8Count = 0
    private(set) var wasTruncated = false

    /// Undecoded trailing bytes retained after `append` (at most 3).
    var pendingUndecodedByteCount: Int { pendingUTF8.count }

    /// Approximate in-memory payload size (completed lines + pending line + undecoded).
    var storageByteEstimate: Int {
        utf8ByteCount(of: lines) + pendingLineUTF8Count + pendingUTF8.count
    }

    mutating func reset() {
        lines = []
        pendingUTF8 = Data()
        pendingLine = ""
        pendingLineUTF8Count = 0
        wasTruncated = false
    }

    mutating func beginAttempt(_ attempt: Int) {
        flushPartialLine()
        appendLogicalLine("\(Self.attemptSeparatorPrefix)\(attempt) ———")
    }

    /// Append raw bytes from a pipe chunk (may be split mid-UTF-8 or mid-line).
    ///
    /// Invariant: after return, `pendingUTF8` holds at most 3 bytes, and only a
    /// valid prefix of an incomplete UTF-8 code point. Invalid bytes are dropped
    /// and mark truncation.
    mutating func append(data: Data) {
        guard !data.isEmpty else { return }

        // Hot path for flood of newline-free bytes once the pending line is full:
        // drop without decoding (O(chunk) scan for breaks only).
        if pendingLineUTF8Count >= Self.maxBytes,
           pendingUTF8.isEmpty,
           !data.contains(where: { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") })
        {
            wasTruncated = true
            return
        }

        pendingUTF8.append(data)
        decodePendingUTF8()
    }

    /// Flush any partial line remaining at EOF / process end.
    mutating func flushEOF() {
        // Drop undecodable trailing bytes — they cannot form a line.
        if !pendingUTF8.isEmpty {
            pendingUTF8.removeAll(keepingCapacity: false)
            wasTruncated = true
        }
        flushPartialLine()
    }

    func tail() -> String {
        var body = lines.joined(separator: "\n")
        if wasTruncated {
            if body.isEmpty {
                body = Self.truncationMarker
            } else {
                body = Self.truncationMarker + "\n" + body
            }
        }
        return body
    }

    /// Text after the last `——— attempt N ———` separator (current attempt only).
    func currentAttemptSegment() -> String {
        let body = lines.joined(separator: "\n")
        guard let range = body.range(
            of: Self.attemptSeparatorPrefix,
            options: .backwards
        ) else {
            return body
        }
        // Skip past the separator line itself.
        let afterPrefix = body[range.lowerBound...]
        if let lineEnd = afterPrefix.firstIndex(of: "\n") {
            return String(afterPrefix[afterPrefix.index(after: lineEnd)...])
        }
        return ""
    }

    // MARK: Private — UTF-8

    /// Decode the whole pending buffer in one pass, then ingest once.
    /// After return, `pendingUTF8` holds at most 3 bytes of a valid incomplete sequence.
    private mutating func decodePendingUTF8() {
        var decoded = String()
        decoded.reserveCapacity(min(pendingUTF8.count, Self.maxBytes * 2))

        var index = pendingUTF8.startIndex
        let end = pendingUTF8.endIndex

        while index < end {
            let byte = pendingUTF8[index]

            // ASCII fast path.
            if byte < 0x80 {
                decoded.append(Character(UnicodeScalar(byte)))
                index = pendingUTF8.index(after: index)
                continue
            }

            let needed = utf8SequenceLength(leading: byte)
            if needed == 0 {
                // Invalid starter / lone continuation — drop and continue.
                wasTruncated = true
                index = pendingUTF8.index(after: index)
                continue
            }

            let remaining = pendingUTF8.distance(from: index, to: end)
            if remaining < needed {
                // Incomplete multi-byte sequence at the end of the buffer.
                let suffix = pendingUTF8[index..<end]
                if isValidUTF8Prefix(Data(suffix)), suffix.count <= 3 {
                    pendingUTF8 = Data(suffix)
                    if !decoded.isEmpty {
                        ingestDecodedText(decoded)
                    }
                    return
                }
                // Invalid incomplete prefix — drop the bad leading byte and retry.
                wasTruncated = true
                index = pendingUTF8.index(after: index)
                continue
            }

            let sequenceEnd = pendingUTF8.index(index, offsetBy: needed)
            let sequence = pendingUTF8[index..<sequenceEnd]
            if let scalarText = String(data: Data(sequence), encoding: .utf8) {
                decoded.append(scalarText)
                index = sequenceEnd
            } else {
                wasTruncated = true
                index = pendingUTF8.index(after: index)
            }
        }

        pendingUTF8.removeAll(keepingCapacity: true)
        if !decoded.isEmpty {
            ingestDecodedText(decoded)
        }
    }

    /// Expected total length of a UTF-8 sequence from its leading byte, or 0 if invalid.
    private func utf8SequenceLength(leading: UInt8) -> Int {
        if leading < 0x80 { return 1 }
        if leading >> 5 == 0b110 { return 2 }
        if leading >> 4 == 0b1110 { return 3 }
        if leading >> 3 == 0b11110 { return 4 }
        return 0
    }

    private func isValidUTF8Prefix(_ data: Data) -> Bool {
        guard let first = data.first else { return true }
        let needed = utf8SequenceLength(leading: first)
        guard needed > 0, data.count < needed else { return false }
        // All subsequent bytes in an incomplete sequence must be continuations.
        for b in data.dropFirst() {
            if b >> 6 != 0b10 { return false }
        }
        return true
    }

    // MARK: Private — lines

    private mutating func ingestDecodedText(_ text: String) {
        guard !text.isEmpty else { return }

        // Fast path: no line breaks in the new text or pending line — just append
        // (still enforcing the pendingLine byte cap). Avoids O(n) components().
        if !text.contains(where: { $0 == "\n" || $0 == "\r" })
            && !pendingLine.contains(where: { $0 == "\n" || $0 == "\r" })
        {
            appendToPendingLineWithoutBreak(text)
            enforceTotalStorage()
            return
        }

        var buffer = pendingLine + text
        // Normalize CRLF so we do not emit empty pieces between \r and \n.
        buffer = buffer.replacingOccurrences(of: "\r\n", with: "\n")

        let endsWithBreak = buffer.hasSuffix("\n") || buffer.hasSuffix("\r")
        var pieces = buffer.components(separatedBy: CharacterSet(charactersIn: "\n\r"))
        if endsWithBreak {
            setPendingLine("")
            if pieces.last?.isEmpty == true {
                pieces.removeLast()
            }
        } else {
            setPendingLine(pieces.popLast() ?? "")
        }

        for piece in pieces where !piece.isEmpty {
            appendLogicalLine(piece)
        }

        // Bound an in-progress line with no newline: truncate in place so we
        // never displace already-captured history to store more pending bytes.
        if pendingLineUTF8Count > Self.maxBytes {
            setPendingLine(utf8Suffix(pendingLine, maxBytes: Self.maxBytes))
            wasTruncated = true
        }
        enforceTotalStorage()
    }

    /// Append newline-free text onto `pendingLine` in O(chunk) time.
    private mutating func appendToPendingLineWithoutBreak(_ text: String) {
        let textCount = text.utf8.count

        if pendingLineUTF8Count >= Self.maxBytes {
            // Already at cap — drop further newline-free input (O(1)).
            wasTruncated = true
            return
        }

        let room = Self.maxBytes - pendingLineUTF8Count
        if textCount <= room {
            pendingLine += text
            pendingLineUTF8Count += textCount
            return
        }

        // Combined content exceeds the cap: keep the most recent maxBytes.
        wasTruncated = true
        if textCount >= Self.maxBytes {
            setPendingLine(utf8Suffix(text, maxBytes: Self.maxBytes))
        } else {
            let keepFromPending = Self.maxBytes - textCount
            setPendingLine(utf8Suffix(pendingLine, maxBytes: keepFromPending) + text)
        }
    }

    private mutating func setPendingLine(_ value: String) {
        pendingLine = value
        pendingLineUTF8Count = value.utf8.count
    }

    private mutating func flushPartialLine() {
        if !pendingLine.isEmpty {
            appendLogicalLine(pendingLine)
            setPendingLine("")
        }
        enforceTotalStorage()
    }

    private mutating func appendLogicalLine(_ line: String) {
        var stored = line
        if stored.utf8.count > Self.maxBytes {
            stored = utf8Prefix(stored, maxBytes: Self.maxBytes)
            wasTruncated = true
        }

        // Never drop prior lines to make room for a newcomer — shrink/skip the
        // new line instead so a monster line cannot erase the whole prior tail.
        let used = utf8ByteCount(of: lines)
        let separator = lines.isEmpty ? 0 : 1
        let room = Self.maxBytes - used - separator
        if room <= 0 {
            wasTruncated = true
            return
        }
        if stored.utf8.count > room {
            stored = utf8Prefix(stored, maxBytes: room)
            wasTruncated = true
        }
        guard !stored.isEmpty else {
            wasTruncated = true
            return
        }

        lines.append(stored)
        while lines.count > Self.maxLines {
            lines.removeFirst()
            wasTruncated = true
        }
        enforceTotalStorage()
    }

    /// Keep completed lines + pending line + undecoded bytes within maxBytes.
    private mutating func enforceTotalStorage() {
        while lines.count > Self.maxLines {
            lines.removeFirst()
            wasTruncated = true
        }
        // Prefer trimming pending / undecoded before dropping completed history.
        while storageByteEstimate > Self.maxBytes {
            let room = max(0, Self.maxBytes - utf8ByteCount(of: lines) - pendingUTF8.count)
            if pendingLineUTF8Count > room {
                setPendingLine(utf8Suffix(pendingLine, maxBytes: room))
                wasTruncated = true
                continue
            }
            if !pendingUTF8.isEmpty && storageByteEstimate > Self.maxBytes {
                // Should be <=3; drop if somehow still over.
                pendingUTF8.removeAll(keepingCapacity: false)
                wasTruncated = true
                continue
            }
            if !lines.isEmpty && storageByteEstimate > Self.maxBytes {
                lines.removeFirst()
                wasTruncated = true
                continue
            }
            break
        }
    }

    private func utf8Prefix(_ string: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var count = 0
        var end = string.startIndex
        for idx in string.indices {
            let scalarBytes = string[idx].utf8.count
            if count + scalarBytes > maxBytes { break }
            count += scalarBytes
            end = string.index(after: idx)
        }
        return String(string[..<end])
    }

    private func utf8Suffix(_ string: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var count = 0
        var start = string.endIndex
        for idx in string.indices.reversed() {
            let scalarBytes = string[idx].utf8.count
            if count + scalarBytes > maxBytes { break }
            count += scalarBytes
            start = idx
        }
        return String(string[start...])
    }

    private func utf8ByteCount(of lines: [String]) -> Int {
        guard !lines.isEmpty else { return 0 }
        let joined = lines.joined(separator: "\n")
        return joined.utf8.count
    }
}

// MARK: - Download progress parser

struct DownloadProgressParser: Sendable {
    struct Result: Equatable, Sendable {
        /// Recognized as Hugging Face / tqdm-shaped download activity.
        var isDownloadProgress: Bool
        /// Known percent when parseable; nil when progress is recognized but % unknown.
        var percent: Int?
        /// True when the line is download-shaped but percent could not be parsed.
        var percentUnknown: Bool
    }

    /// Any non-empty output refreshes startup liveness (separate from downloading UI).
    static func isStartupActivity(_ line: String) -> Bool {
        !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func parse(_ line: String) -> Result {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(isDownloadProgress: false, percent: nil, percentUnknown: false)
        }

        // Reject bare resource meters like `CPU 45%` / `Memory: 80%`.
        if looksLikeBareResourceMeter(trimmed) {
            return Result(isDownloadProgress: false, percent: nil, percentUnknown: false)
        }

        guard isHuggingFaceOrTqdmShaped(trimmed) else {
            return Result(isDownloadProgress: false, percent: nil, percentUnknown: false)
        }

        if let percent = extractPercent(from: trimmed) {
            return Result(isDownloadProgress: true, percent: percent, percentUnknown: false)
        }
        return Result(isDownloadProgress: true, percent: nil, percentUnknown: true)
    }

    private static func looksLikeBareResourceMeter(_ line: String) -> Bool {
        // Reject cpu/mem/ram/gpu/load meters even when trailing junk follows the %.
        let pattern = #"^(?i)(cpu|mem(ory)?|ram|gpu|load)\s*:?\s*\d{1,3}(?:\.\d+)?%"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isHuggingFaceOrTqdmShaped(_ line: String) -> Bool {
        // Typical HF hub / tqdm: `name:  45%|████| 1.57G/3.50G` or `Fetching 12 files:  30%|`
        if line.range(of: #"\d{1,3}(?:\.\d+)?%\s*\|"#, options: .regularExpression) != nil {
            return true
        }
        // HF/tqdm activity without a parseable percent (unknown %).
        if line.range(
            of: #"(?i)(fetching\s+\d+\s+files|downloading|model\.safetensors|huggingface|hf_hub)"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        // Progress with size fractions even without a bar.
        if line.range(
            of: #"\d+(?:\.\d+)?%\s+\d+(?:\.\d+)?[KMG]/\d+(?:\.\d+)?[KMG]"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        // tqdm-style bar without a leading percent token.
        if line.contains("|") && line.range(
            of: #"(?i)(fetching|downloading|safetensors|huggingface)"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return false
    }

    private static func extractPercent(from line: String) -> Int? {
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
}

// MARK: - Pure presentation helpers (AppKit-free)

enum DictationPresentation: Sendable {
    /// Concise server-row text for a dictation state.
    static func serverRowTitle(for state: DictationState) -> String {
        switch state {
        case .downloading(let percent):
            if let percent {
                return "Server: Downloading model… \(percent)%"
            }
            return "Server: Downloading model…"
        case .starting:
            return "Server: Starting…"
        case .restarting(let status):
            return "Server: \(status.menuSummary)"
        case .ready, .listening, .flushing:
            return "Server: Running"
        case .idle:
            return "Server: Stopped"
        case .failed(let failure):
            switch failure {
            case .server(let server):
                return "Server: \(server.menuSummary)"
            case .secureInput:
                return "Server: Running"
            case .accessibility:
                return "Server: —"
            case .app:
                return "Server: —"
            }
        }
    }

    static func showsServerDetails(for state: DictationState) -> Bool {
        switch state {
        case .restarting, .failed(.server):
            return true
        default:
            return false
        }
    }

    static func showsRetryServer(for state: DictationState) -> Bool {
        if case .failed(.server) = state { return true }
        return false
    }

    static func detailsText(for state: DictationState) -> String? {
        switch state {
        case .restarting(let status):
            return restartDetails(status)
        case .failed(.server(let failure)):
            return failure.detailsText
        default:
            return nil
        }
    }

    private static func restartDetails(_ status: ServerRestartStatus) -> String {
        var lines: [String] = []
        lines.append("summary: \(status.menuSummary)")
        lines.append("attempt: \(status.attempt)/\(status.maxAttempts)")
        let seconds = Double(status.backoff.components.seconds)
            + Double(status.backoff.components.attoseconds) / 1e18
        lines.append(String(format: "backoff: %.1fs", seconds))
        if let command = status.latestExit.command {
            lines.append(contentsOf: command.detailDescription.split(separator: "\n").map(String.init))
        }
        if let port = status.latestExit.port {
            lines.append("port: \(port)")
        }
        switch status.latestExit.reason {
        case .exited(let code):
            lines.append("exit status: \(code)")
        case .signaled(let signal):
            lines.append("exit signal: \(signal)")
        case .timedOut:
            lines.append("exit reason: readiness timed out")
        case .launchFailed(let message):
            lines.append("exit reason: launch failed (\(message))")
        case .unknown:
            lines.append("exit reason: unknown")
        }
        let tail = status.latestExit.stderrTail
        if tail.isEmpty {
            lines.append("stderr: (empty)")
        } else {
            lines.append("stderr:")
            lines.append(tail)
        }
        return lines.joined(separator: "\n")
    }
}

/// Pure mapping from supervisor state → next dictation UI state (AppKit-free).
/// Used by the controller and by presentation regression tests.
enum DictationServerStateReducer {
    static func apply(
        _ serverState: ServerSupervisor.State,
        current: DictationState
    ) -> DictationState {
        switch serverState {
        case .idle, .stopped:
            return .idle
        case .launching, .waitingForReady:
            if current == .listening || current == .flushing {
                return current
            }
            return .starting
        case .restarting(let status):
            // Always surface restart status, even after interrupting an active session.
            return .restarting(status)
        case .downloading(let percent):
            if current == .listening || current == .flushing {
                return current
            }
            return .downloading(percent: percent)
        case .running:
            if current == .listening || current == .flushing {
                return current
            }
            return .ready
        case .failed(let failure):
            return .failed(.server(failure))
        }
    }
}
