import AppKit
import ApplicationServices
import Carbon
import Foundation
import os

/// Posts dictation edits at the caret via synthetic keyboard events.
///
/// What to type is decided by ``DictationTypist``; this type only executes
/// ``TypingEdit``s. Terminal-like targets (Terminal, iTerm, shells, etc.) get
/// newlines/tabs stripped to spaces so a mid-stream line break cannot submit a
/// shell command. If focus moves to another app mid-session, typing stops —
/// backspaces aimed at the dictation must never land in a different window.
@MainActor
final class TextInserter {
    /// When true, `\n` / `\r` / `\t` become spaces before any keystroke is posted.
    private(set) var stripLineBreaks = false
    /// Frontmost app when the session began; edits are refused once it changes.
    private var targetPID: pid_t?
    /// Set once focus left the session's target app.
    private(set) var targetLost = false

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

    /// Probe the frontmost target: remember it and arm line-break stripping.
    func beginSession() {
        let decision = Self.detectTerminalLikeTarget()
        stripLineBreaks = decision.isTerminalLike
        targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        targetLost = false
        AppLog.insertion.info(
            "insertion stripLineBreaks=\(self.stripLineBreaks, privacy: .public) terminalLike=\(decision.isTerminalLike, privacy: .public) reason=\(decision.reason, privacy: .public) bundle=\(decision.bundleID ?? "<none>", privacy: .public)"
        )
    }

    /// Normalize transcript text the way it will be typed.
    func prepared(_ text: String) -> String {
        stripLineBreaks ? Self.sanitizeForTerminal(text) : text
    }

    /// Execute one edit. Returns false (and posts nothing) once focus has left
    /// the session's target app.
    @discardableResult
    func perform(_ edit: TypingEdit) -> Bool {
        guard !edit.isEmpty else { return true }
        guard !targetLost else { return false }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let targetPID, frontmost != targetPID {
            targetLost = true
            AppLog.insertion.error(
                "focus left dictation target (pid \(targetPID, privacy: .public) → \(frontmost ?? -1, privacy: .public)); typing stopped"
            )
            return false
        }
        deleteBackward(edit.deleteCount)
        insert(edit.insert)
        return true
    }

    /// Post `count` backward-delete key events (draft correction).
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
