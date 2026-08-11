import AppKit
import ApplicationServices
import Carbon
import Foundation
import os

/// Inserts dictated text at the caret via synthetic Unicode keyboard events.
///
/// Always streams live. Terminal-like targets (Terminal, iTerm, shells, etc.)
/// strip newlines/tabs to spaces on insert so a mid-stream line break cannot
/// submit a shell command, while still showing partials as you speak.
@MainActor
final class TextInserter {
    enum Mode: String, Sendable {
        case stream
        /// Legacy: accumulate until stop. Unused — terminals stream with
        /// line-break stripping instead.
        case buffer
    }

    private(set) var mode: Mode = .stream
    /// When true, `\n` / `\r` / `\t` become spaces before any keystroke is posted.
    private(set) var stripLineBreaks = false
    private var buffer = ""

    /// Exact bundle IDs treated as terminal emulators.
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

    /// Probe the frontmost target and arm stream + optional line-break stripping.
    func beginSession() {
        buffer = ""
        let decision = Self.detectTerminalLikeTarget()
        mode = .stream
        stripLineBreaks = decision.isTerminalLike
        AppLog.insertion.info(
            "insertion mode=\(self.mode.rawValue, privacy: .public) stripLineBreaks=\(self.stripLineBreaks, privacy: .public) terminalLike=\(decision.isTerminalLike, privacy: .public) reason=\(decision.reason, privacy: .public) bundle=\(decision.bundleID ?? "<none>", privacy: .public)"
        )
    }

    /// Normalize text the same way keystrokes will (so session tracking matches).
    func prepared(_ text: String) -> String {
        stripLineBreaks ? Self.sanitizeForTerminal(text) : text
    }

    /// Route a transcript delta (append-only, e.g. Voxtral).
    func handleDelta(_ text: String) {
        let chunk = prepared(text)
        guard !chunk.isEmpty else { return }
        switch mode {
        case .stream:
            _ = insert(chunk)
        case .buffer:
            buffer.append(chunk)
        }
    }

    /// Buffer-mode stop path (legacy). Stream mode is a no-op.
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

    /// Apply a live absolute draft (Parakeet MLX partials) without ending the session.
    /// Returns the text that is now considered typed (after line-break stripping).
    @discardableResult
    func applyLiveTranscript(previouslyEmitted: String, text: String) -> String {
        let previous = prepared(previouslyEmitted)
        let next = prepared(text)
        switch mode {
        case .stream:
            _ = Self.reconcileStream(
                previouslyEmitted: previous,
                finalText: next,
                insert: { [weak self] chunk in _ = self?.insert(chunk) },
                deleteBackward: { [weak self] count in self?.deleteBackward(count) }
            )
            return next
        case .buffer:
            buffer = next
            return next
        }
    }

    /// Apply the authoritative final transcript after mic release.
    /// Returns the effective final text for stream mode (or inserted buffer text).
    @discardableResult
    func commitFinal(previouslyEmitted: String, finalText: String) -> String {
        let previous = prepared(previouslyEmitted)
        let final = prepared(finalText)
        switch mode {
        case .stream:
            return Self.reconcileStream(
                previouslyEmitted: previous,
                finalText: final,
                insert: { [weak self] text in _ = self?.insert(text) },
                deleteBackward: { [weak self] count in self?.deleteBackward(count) }
            )
        case .buffer:
            buffer = final
            return flush()
        }
    }

    /// Shared pure reconciliation for stream mode (unit-testable).
    nonisolated static func reconcileStream(
        previouslyEmitted: String,
        finalText: String,
        insert: (String) -> Void,
        deleteBackward: (Int) -> Void
    ) -> String {
        if finalText == previouslyEmitted {
            return ""
        }
        if finalText.hasPrefix(previouslyEmitted) {
            let rest = String(finalText.dropFirst(previouslyEmitted.count))
            if !rest.isEmpty {
                insert(rest)
            }
            return rest
        }
        if previouslyEmitted.isEmpty {
            if !finalText.isEmpty {
                insert(finalText)
            }
            return finalText
        }

        let shared = previouslyEmitted.commonPrefix(with: finalText)
        let deleteCount = previouslyEmitted.count - shared.count
        if deleteCount > 0 {
            deleteBackward(deleteCount)
        }
        let tail = String(finalText.dropFirst(shared.count))
        if !tail.isEmpty {
            insert(tail)
        }
        return finalText
    }

    /// Post `count` backward-delete key events (stream draft correction).
    func deleteBackward(_ count: Int) {
        guard count > 0,
              let source = CGEventSource(stateID: .combinedSessionState)
        else {
            return
        }
        let backspaceKey: CGKeyCode = 0x33
        for _ in 0 ..< count {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: backspaceKey, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: backspaceKey, keyDown: false)
            else {
                continue
            }
            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
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

    /// Collapse newlines/tabs so synthetic key events cannot submit a shell line.
    static func sanitizeForTerminal(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    // MARK: - CGEvent insertion

    /// Post Unicode text as keyboard events, chunked at 20 UTF-16 units, to
    /// `.cgAnnotatedSessionEventTap` (localvoxtral's proven path).
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
