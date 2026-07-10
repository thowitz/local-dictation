import AppKit
import ApplicationServices
import Carbon
import Foundation
import os

/// Inserts dictated text at the caret via synthetic Unicode keyboard events.
///
/// Two modes, chosen once at dictation start from the then-frontmost target:
/// - **stream**: each transcript delta is typed immediately.
/// - **buffer**: deltas accumulate; on stop the buffer is sanitized (newlines/tabs
///   → spaces) and inserted once. Used for terminal-like targets where live
///   streaming risks submitting a shell prompt.
@MainActor
final class TextInserter {
    enum Mode: String, Sendable {
        case stream
        case buffer
    }

    private(set) var mode: Mode = .stream
    private var buffer = ""

    /// Exact bundle IDs treated as terminal emulators (PLAN step 3 / fact #5).
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
    ]

    /// UTF-16 units per CGEvent (localvoxtral `postUnicodeTextEvents` chunk size).
    private static let unicodeChunkSize = 20

    // MARK: - Secure input

    /// `true` when macOS Secure Keyboard Entry is active. Synthetic key events
    /// are dropped in that state, so dictation must refuse to start.
    static func isSecureEventInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    // MARK: - Session

    /// Probe the frontmost target and arm stream or buffer mode.
    func beginSession() {
        buffer = ""
        let decision = Self.detectTerminalLikeTarget()
        mode = decision.isTerminalLike ? .buffer : .stream
        AppLog.insertion.info(
            "insertion mode=\(self.mode.rawValue, privacy: .public) terminalLike=\(decision.isTerminalLike, privacy: .public) reason=\(decision.reason, privacy: .public) bundle=\(decision.bundleID ?? "<none>", privacy: .public)"
        )
    }

    /// Route a transcript delta according to the session mode.
    func handleDelta(_ text: String) {
        guard !text.isEmpty else { return }
        switch mode {
        case .stream:
            _ = insert(text)
        case .buffer:
            buffer.append(text)
        }
    }

    /// Buffer-mode stop path: sanitize and insert the accumulated text once.
    /// Stream mode has already typed deltas live; this is a no-op there.
    @discardableResult
    func flush() -> String {
        switch mode {
        case .stream:
            return ""
        case .buffer:
            let raw = buffer
            buffer = ""
            let sanitized = Self.sanitizeForTerminal(raw)
            if !sanitized.isEmpty {
                _ = insert(sanitized)
            }
            return sanitized
        }
    }

    /// Esc-cancel path: drop any untyped buffer. Already-typed stream text stays.
    func discard() {
        buffer = ""
    }

    // MARK: - Terminal detection

    struct TargetDecision: Sendable {
        let isTerminalLike: Bool
        let reason: String
        let bundleID: String?
    }

    static func detectTerminalLikeTarget() -> TargetDecision {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let bundleID, terminalBundleIDs.contains(bundleID) {
            return TargetDecision(isTerminalLike: true, reason: "bundle-match", bundleID: bundleID)
        }

        switch probeFocusedValueSettable() {
        case .noFocusedElement:
            return TargetDecision(isTerminalLike: true, reason: "ax-probe-no-focus", bundleID: bundleID)
        case .valueNotSettable:
            return TargetDecision(isTerminalLike: true, reason: "ax-probe-unsettable", bundleID: bundleID)
        case .valueSettable:
            return TargetDecision(isTerminalLike: false, reason: "ax-probe-writable", bundleID: bundleID)
        case .probeUnavailable:
            return TargetDecision(isTerminalLike: false, reason: "ax-probe-unavailable", bundleID: bundleID)
        }
    }

    private enum FocusedElementProbe {
        case noFocusedElement
        case valueNotSettable
        case valueSettable
        case probeUnavailable
    }

    private static func probeFocusedValueSettable() -> FocusedElementProbe {
        guard AXIsProcessTrusted() else { return .probeUnavailable }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: AnyObject?
        let focusStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )
        switch focusStatus {
        case .success:
            break
        case .noValue:
            return .noFocusedElement
        default:
            return .probeUnavailable
        }

        guard let focusedObject,
              CFGetTypeID(focusedObject) == AXUIElementGetTypeID()
        else {
            return .noFocusedElement
        }

        let element = unsafeDowncast(focusedObject, to: AXUIElement.self)
        var settable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        guard settableStatus == .success else { return .probeUnavailable }
        return settable.boolValue ? .valueSettable : .valueNotSettable
    }

    static func sanitizeForTerminal(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    // MARK: - CGEvent insertion

    /// Post Unicode text as keyboard events, chunked at 20 UTF-16 units, to
    /// `.cgAnnotatedSessionEventTap` (localvoxtral's proven path). No inter-chunk
    /// delay — localvoxtral does not use one.
    @discardableResult
    func insert(_ text: String) -> Bool {
        guard !text.isEmpty,
              let source = CGEventSource(stateID: .combinedSessionState)
        else {
            return false
        }

        var didPost = false
        let utf16 = Array(text.utf16)
        let chunkSize = Self.unicodeChunkSize

        for i in stride(from: 0, to: utf16.count, by: chunkSize) {
            let end = min(i + chunkSize, utf16.count)
            var chunk = Array(utf16[i..<end])

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                continue
            }

            keyDown.flags = []
            keyUp.flags = []
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
            didPost = true
        }

        return didPost
    }
}

extension AppLog {
    static let insertion = Logger(subsystem: AppLog.subsystem, category: "insertion")
}
