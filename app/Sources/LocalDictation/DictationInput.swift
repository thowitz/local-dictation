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

// MARK: - Cancellation / transcript barrier

/// Phase of an active dictation session for transcript gating.
enum TranscriptSessionPhase: Equatable, Sendable {
    case inactive
    case listening
    case flushing
}

/// Pure Esc-cancellation barrier: quarantine deltas/done until `input_audio_buffer.cleared`,
/// and block pending starts while awaiting that acknowledgement.
struct CancellationBarrier: Equatable, Sendable {
    private(set) var awaitingBufferClear = false

    var isAwaitingClear: Bool { awaitingBufferClear }

    /// Accept transcript only in `.listening`/`.flushing` while the barrier is open.
    func shouldAcceptTranscript(phase: TranscriptSessionPhase) -> Bool {
        switch phase {
        case .listening, .flushing:
            return !awaitingBufferClear
        case .inactive:
            return false
        }
    }

    /// Whether a pending start may begin (barrier must be open).
    func shouldAllowStart(hasPendingIntent: Bool) -> Bool {
        hasPendingIntent && !awaitingBufferClear
    }

    /// Esc cancel: close the barrier until the server acks clear.
    mutating func beginCancel() {
        awaitingBufferClear = true
    }

    /// Clear frame could not be enqueued — open immediately (reconnect owns a fresh session).
    mutating func clearEnqueueFailed() {
        awaitingBufferClear = false
    }

    /// Server ack: open the barrier. Returns `true` only if we were awaiting.
    @discardableResult
    mutating func bufferCleared() -> Bool {
        guard awaitingBufferClear else { return false }
        awaitingBufferClear = false
        return true
    }

    /// Disconnect / interrupt / hard failure — drop any outstanding wait.
    mutating func reset() {
        awaitingBufferClear = false
    }
}

// MARK: - Hot-key edge latch

/// Pure per-instance edge/repeat suppression for Carbon hotkeys.
///
/// - `requiresReleaseToRearm: true` (F13): deliver only the first press while down; matching
///   release re-arms. Missed release sticks until `reset()`.
/// - `requiresReleaseToRearm: false` (⌥⌘D / Esc): suppress true key-repeat while down, but a
///   later press after a dropped release still delivers (Carbon hotkeys do not key-repeat).
struct HotKeyEdgeLatch: Equatable, Sendable {
    /// When `true`, a press while already down is ignored until `released()` or `reset()`.
    var requiresReleaseToRearm: Bool
    private var isDown = false

    init(requiresReleaseToRearm: Bool = true) {
        self.requiresReleaseToRearm = requiresReleaseToRearm
    }

    /// Returns `true` when the press should be delivered to the app.
    mutating func pressed() -> Bool {
        if isDown {
            if requiresReleaseToRearm {
                return false
            }
            // Missed release on a toggle/Esc key — re-arm as a fresh press.
            return true
        }
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
