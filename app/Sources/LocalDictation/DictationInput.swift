import Foundation

// MARK: - Mic key mode preference

/// Persisted F13 / remapped-mic-key input mode.
/// Applies only to the mic key; ⌥⌘D and menu Start/Stop remain toggle.
enum MicKeyMode: String, CaseIterable, Sendable, Equatable {
    case holdToTalk
    case toggle

    /// Defaults key shared with `AppPrefs.micKeyMode` (added when the menu lands).
    static let preferenceKey = "micKeyMode"

    var displayTitle: String {
        switch self {
        case .holdToTalk: return "Hold to Talk"
        case .toggle: return "Press to Toggle"
        }
    }

    /// Missing or invalid raw value → `.toggle` (preserves today's behavior).
    static func read(from defaults: UserDefaults) -> MicKeyMode {
        guard let raw = defaults.string(forKey: preferenceKey),
              let mode = MicKeyMode(rawValue: raw)
        else {
            return .toggle
        }
        return mode
    }

    static func write(_ mode: MicKeyMode, to defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: preferenceKey)
    }
}

// MARK: - Gesture interpreter

/// Actions emitted by the F13 / mic-key gesture interpreter.
enum MicKeyGestureAction: Equatable, Sendable {
    case beginHold
    case endHold
    case toggle
}

/// Latches the configured mode on key-down and emits gesture actions.
/// Preference changes while a key is held apply only to the next gesture.
struct MicKeyGestureInterpreter: Equatable, Sendable {
    private var isDown = false
    private var latchedMode: MicKeyMode?

    /// First accepted down while up. Repeated downs while held are ignored.
    mutating func keyDown(mode: MicKeyMode) -> MicKeyGestureAction? {
        guard !isDown else { return nil }
        isDown = true
        latchedMode = mode
        switch mode {
        case .holdToTalk: return .beginHold
        case .toggle: return .toggle
        }
    }

    /// Matching up for the latched down. Unmatched releases are ignored.
    /// Toggle mode: up is a no-op. Hold mode: emits `.endHold`.
    mutating func keyUp() -> MicKeyGestureAction? {
        guard isDown else { return nil }
        let mode = latchedMode
        isDown = false
        latchedMode = nil
        switch mode {
        case .holdToTalk: return .endHold
        case .toggle, .none: return nil
        }
    }

    /// Clears in-flight latch (quit / hotkey unregister).
    mutating func reset() {
        isDown = false
        latchedMode = nil
    }
}

// MARK: - Intent tracker

/// Why the controller wants to start (or has started) listening.
enum DictationStartIntent: Equatable, Sendable {
    case manualToggle
    case micHold
}

/// Outcome of a physical hold-key release against pending/active intent.
enum HoldReleaseOutcome: Equatable, Sendable {
    /// Pending `.micHold` cleared before readiness — do not begin listening.
    case canceledPending
    /// Active `.micHold` owned the session — request exactly one stop/commit.
    case requestStop
    /// No matching hold intent (manual session, already cleared, etc.).
    case ignored
}

/// Explicit pending/active start intent, replacing the ambiguous `wantsListening` flag.
struct DictationIntentTracker: Equatable, Sendable {
    private(set) var pending: DictationStartIntent?
    private(set) var active: DictationStartIntent?

    /// Queue a start request (e.g. hold during warm-up, or manual start from idle).
    mutating func queue(_ intent: DictationStartIntent) {
        pending = intent
    }

    /// Whether readiness should call `beginListening` for the current pending intent.
    var shouldBeginOnReadiness: Bool {
        pending != nil
    }

    /// Move pending → active after permission checks and audio start succeed.
    mutating func activatePending() {
        guard let pending else { return }
        active = pending
        self.pending = nil
    }

    /// Hold-key release: cancel pending hold, stop an owned active hold, or ignore.
    mutating func handleHoldRelease() -> HoldReleaseOutcome {
        if pending == .micHold {
            pending = nil
            return .canceledPending
        }
        if active == .micHold {
            active = nil
            return .requestStop
        }
        return .ignored
    }

    /// Transport/runtime interrupt: drop all intent so reconnect cannot reopen the mic.
    /// A later physical hold release is a no-op; a new press can queue again.
    mutating func interruptActiveSession() {
        clearAll()
    }

    /// Esc, hard failure, or completed finalization — clear all intent.
    mutating func clearAll() {
        pending = nil
        active = nil
    }
}

// MARK: - Hot-key edge latch

/// Pure per-instance edge/repeat suppression for Carbon hotkeys.
/// Delivers only the first pressed while down and only the matching release.
struct HotKeyEdgeLatch: Equatable, Sendable {
    private var isDown = false

    /// Returns `true` only for the first pressed event of a down cycle.
    mutating func pressed() -> Bool {
        guard !isDown else { return false }
        isDown = true
        return true
    }

    /// Returns `true` only for the matching release after an accepted press.
    mutating func released() -> Bool {
        guard isDown else { return false }
        isDown = false
        return true
    }

    mutating func reset() {
        isDown = false
    }
}
