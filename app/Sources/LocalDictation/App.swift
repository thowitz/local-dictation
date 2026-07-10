import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Foundation
import ServiceManagement
import os

// MARK: - Dictation state machine

enum DictationFailure: Equatable, Sendable {
    case server(ServerFailure)
    case secureInput(String)
    case accessibility(String)
    case app(String)

    var menuSummary: String {
        switch self {
        case .server(let failure):
            return failure.menuSummary
        case .secureInput(let message), .accessibility(let message), .app(let message):
            return message
        }
    }
}

enum DictationState: Equatable, Sendable {
    case idle
    case starting
    case downloading(percent: Int?)
    case ready
    case listening
    case flushing
    case restarting(ServerRestartStatus)
    case failed(DictationFailure)

    /// Nil → flattened template bitmap (tracks menu-bar light/dark). Colored
    /// only for transient / active states. Raw SF Symbol `isTemplate` stays
    /// black on a dark/fullscreen bar, so idle/ready must be flattened first.
    var menuBarTint: NSColor? {
        switch self {
        case .idle, .ready:
            return nil
        case .starting, .downloading, .restarting:
            return .systemOrange
        case .listening:
            return .systemBlue
        case .flushing:
            return .systemPurple
        case .failed:
            return .systemRed
        }
    }

    var statusTitle: String {
        switch self {
        case .idle:
            return "Idle"
        case .starting:
            return "Starting…"
        case .downloading(let percent):
            if let percent {
                return "Downloading model… \(percent)%"
            }
            return "Downloading model…"
        case .ready:
            return "Ready"
        case .listening:
            return "Listening"
        case .flushing:
            return "Flushing…"
        case .restarting(let status):
            return status.menuSummary
        case .failed(let failure):
            return failure.menuSummary
        }
    }
}

// MARK: - Persisted prefs

private enum AppPrefs {
    static let firstRunChecksCompleted = "firstRunChecksCompleted"
    static let playSoundsEnabled = "playSoundsEnabled"
    static let micKeyMode = MicKeyMode.preferenceKey
}

// MARK: - Controller

@MainActor
final class DictationController {
    private(set) var state: DictationState = .idle {
        didSet {
            onStateChange?(state)
        }
    }

    var onStateChange: ((DictationState) -> Void)?

    private let config: AppConfig
    private let supervisor: ServerSupervisor
    private let realtime: RealtimeClient
    private let audio = AudioCapture()
    private let textInserter = TextInserter()
    private let indicator = IndicatorPanel()
    private let sounds = IndicatorSounds.shared
    private let escapeHotKey = CarbonHotKey(
        keyCode: UInt32(kVK_Escape),
        modifiers: 0,
        signature: OSType(0x4C444573), // LDEs
        id: 1
    )

    private var sessionTranscript = ""
    private var intent = DictationIntentTracker()
    /// Set while waiting for `input_audio_buffer.cleared` after Esc (wired in a later slice).
    private var awaitingBufferClear = false
    private var indicatorActive = false

    init(config: AppConfig) {
        self.config = config
        self.supervisor = ServerSupervisor(config: config)
        self.realtime = RealtimeClient(endpoint: config.websocketURL)

        escapeHotKey.onPressed = { [weak self] in
            self?.cancelDictation()
        }

        supervisor.onStateChange = { [weak self] serverState in
            Task { @MainActor in
                self?.handleServerState(serverState)
            }
        }

        realtime.setCallbacks(
            RealtimeClient.Callbacks(
                onDelta: { [weak self] delta in
                    Task { @MainActor in
                        self?.handleDelta(delta)
                    }
                },
                onDone: { [weak self] transcript in
                    Task { @MainActor in
                        self?.handleDone(transcript)
                    }
                },
                onConnectionState: { [weak self] connection in
                    Task { @MainActor in
                        self?.handleConnectionState(connection)
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor in
                        AppLog.general.error("Realtime error: \(message, privacy: .public)")
                        // Don't flip the whole UI to error on transient WS blips while idle/ready.
                        if self?.state == .listening || self?.state == .flushing {
                            self?.intent.clearAll()
                            self?.awaitingBufferClear = false
                            self?.endIndicatorSession(playSound: true)
                            self?.transition(to: .failed(.app(message)))
                        }
                    }
                },
                onBufferCleared: { [weak self] in
                    Task { @MainActor in
                        self?.handleBufferCleared()
                    }
                }
            )
        )
    }

    func bootstrap() {
        transition(to: .starting)
        supervisor.start()
    }

    /// Toggle: start when idle/ready; commit+flush when listening.
    func toggleDictation() {
        switch state {
        case .listening:
            stopDictation()
        case .ready, .idle, .failed:
            startDictation()
        default:
            break
        }
    }

    /// Hold-to-talk down: queue `.micHold` during warm-up; begin when ready + connected.
    func beginHoldDictation() {
        requestStart(intent: .micHold)
    }

    /// Hold-to-talk up: cancel a pending hold, or stop an owned active hold session.
    func endHoldDictation() {
        switch intent.handleHoldRelease() {
        case .canceledPending:
            AppLog.general.info("Hold released before readiness — pending intent cleared")
        case .requestStop:
            stopDictation()
        case .ignored:
            break
        }
    }

    func startDictation() {
        requestStart(intent: .manualToggle)
    }

    private func requestStart(intent startIntent: DictationStartIntent) {
        if TextInserter.isSecureEventInputEnabled() {
            intent.clearAll()
            let message = "Secure input is enabled — dictation refused."
            AppLog.general.error("\(message, privacy: .public)")
            transition(to: .failed(.secureInput(message)))
            return
        }

        if !AXIsProcessTrusted() {
            intent.clearAll()
            let message = "Accessibility permission required — grant it in System Settings."
            AppLog.general.error("\(message, privacy: .public)")
            transition(to: .failed(.accessibility(message)))
            return
        }

        switch state {
        case .ready:
            intent.queue(startIntent)
            beginListeningIfPendingIntent()
        case .listening, .flushing:
            return
        case .starting, .downloading, .restarting:
            // Hold may queue during warm-up; manual toggle stays a no-op here.
            if startIntent == .micHold {
                intent.queue(.micHold)
            }
            return
        case .idle, .failed:
            intent.queue(startIntent)
            switch state {
            case .idle:
                transition(to: .starting)
                supervisor.start()
            case .failed(.server):
                // Terminal server failure: retry supervision without opening the mic yet.
                transition(to: .starting)
                supervisor.retry()
            default:
                break
            }
            return
        }
    }

    func stopDictation() {
        guard state == .listening else { return }
        intent.clearAll()
        // Keep Esc armed through flushing so cancel still works mid-flush.
        transition(to: .flushing)
        updateIndicatorProcessing()
        audio.stop()
        if !realtime.commitFinal() {
            // Commit could not be enqueued — tear down locally instead of hanging in flushing.
            AppLog.general.error("commitFinal enqueue failed — tearing down locally")
            escapeHotKey.unregister()
            textInserter.discard()
            sessionTranscript = ""
            endIndicatorSession(playSound: true)
            if realtime.isConnected, case .running = supervisor.state {
                transition(to: .ready)
            } else {
                transition(to: .starting)
            }
            return
        }
        AppLog.general.info("Stop dictation — commit final sent")
    }

    /// Esc while active: stop immediately with no flush wait. Already-typed
    /// stream text stays; buffer-mode buffer is discarded.
    func cancelDictation() {
        guard state == .listening || state == .flushing else { return }
        intent.clearAll()
        escapeHotKey.unregister()
        audio.stop()
        textInserter.discard()
        sessionTranscript = ""
        endIndicatorSession(playSound: true)

        // Quarantine trailing realtime output until the server acks clear.
        awaitingBufferClear = true
        if !realtime.clearBuffer() {
            // Clear could not be enqueued — a reconnect owns a fresh session.
            awaitingBufferClear = false
            AppLog.general.info("Dictation cancelled (Esc) — clear enqueue failed, relying on reconnect")
        } else {
            AppLog.general.info("Dictation cancelled (Esc) — awaiting buffer clear")
        }

        if realtime.isConnected, case .running = supervisor.state {
            transition(to: .ready)
        } else {
            transition(to: .starting)
        }
    }

    // MARK: - Internals

    private func beginListening() {
        guard state == .ready || state == .listening else { return }
        guard !awaitingBufferClear else { return }
        guard intent.shouldBeginOnReadiness else { return }
        guard case .running = supervisor.state, realtime.isConnected else { return }

        if TextInserter.isSecureEventInputEnabled() {
            intent.clearAll()
            let message = "Secure input is enabled — dictation refused (synthetic keys are dropped)."
            AppLog.general.error("\(message, privacy: .public)")
            transition(to: .failed(.secureInput(message)))
            return
        }

        if !AXIsProcessTrusted() {
            intent.clearAll()
            let message = "Accessibility permission required — grant it in System Settings."
            AppLog.general.error("\(message, privacy: .public)")
            transition(to: .failed(.accessibility(message)))
            return
        }

        // Do not clearBuffer here — every clear ack must belong to an Esc cancel
        // so an older start-time acknowledgement cannot open the barrier early.
        sessionTranscript = ""
        textInserter.beginSession()

        do {
            try audio.start { [weak self] chunk in
                self?.realtime.sendAudio(chunk)
            }
        } catch {
            intent.clearAll()
            textInserter.discard()
            transition(to: .failed(.app(error.localizedDescription)))
            return
        }

        intent.activatePending()
        escapeHotKey.register()
        showIndicatorListening()
        transition(to: .listening)
        AppLog.general.info(
            "Dictation started — mode=\(self.textInserter.mode.rawValue, privacy: .public)"
        )
    }

    private func beginListeningIfPendingIntent() {
        guard !awaitingBufferClear else { return }
        guard intent.shouldBeginOnReadiness else { return }
        guard case .running = supervisor.state, realtime.isConnected else { return }
        beginListening()
    }

    private func handleBufferCleared() {
        guard awaitingBufferClear else { return }
        awaitingBufferClear = false
        AppLog.general.info("Buffer cleared — barrier open")
        beginListeningIfPendingIntent()
    }

    private func showIndicatorListening() {
        sounds.playStart()
        indicator.show(at: CaretLocator.caretAnchor())
        indicatorActive = true
    }

    private func updateIndicatorProcessing() {
        guard indicatorActive else { return }
        indicator.update(state: .processing)
    }

    private func endIndicatorSession(playSound: Bool) {
        guard indicatorActive else { return }
        indicator.hide()
        indicatorActive = false
        if playSound {
            sounds.playStop()
        }
    }

    /// Retry a terminal server failure without opening the microphone.
    func retryServer() {
        intent.clearAll()
        awaitingBufferClear = false
        transition(to: .starting)
        supervisor.retry()
    }

    private func handleServerState(_ serverState: ServerSupervisor.State) {
        switch serverState {
        case .idle, .stopped:
            if state != .idle {
                interruptActiveSessionIfNeeded()
                realtime.disconnect()
                transition(to: .idle)
            }

        case .launching, .waitingForReady:
            if state != .listening && state != .flushing {
                transition(to: .starting)
            }

        case .restarting(let status):
            // Process died between generations — interrupt any active session,
            // then ALWAYS surface Restarting N/5 (do not leave UI as listening
            // for a later generic .starting from the realtime disconnect path).
            interruptActiveSessionIfNeeded()
            transition(to: .restarting(status))

        case .downloading(let percent):
            if state != .listening && state != .flushing {
                transition(to: .downloading(percent: percent))
            }

        case .running:
            // Open (or keep) the persistent WebSocket once the server is healthy.
            // After an interruption, intent was cleared — do not reopen mic unless
            // a still-pending request remains (e.g. hold held through warm-up).
            if !realtime.isConnected {
                realtime.connect()
            } else if state != .listening && state != .flushing {
                transition(to: .ready)
                beginListeningIfPendingIntent()
            }

        case .failed(let failure):
            interruptActiveSessionIfNeeded()
            realtime.disconnect()
            transition(to: .failed(.server(failure)))
        }
    }

    /// Narrow crash/interrupt cleanup: stop audio, keep already-inserted live
    /// text, discard uninserted terminal-target buffer, end indicator, clear
    /// Esc + intent. Does not reopen the mic on later recovery.
    private func interruptActiveSessionIfNeeded() {
        let wasActive = state == .listening || state == .flushing
        guard wasActive else { return }
        intent.interruptActiveSession()
        awaitingBufferClear = false
        escapeHotKey.unregister()
        audio.stop()
        // discard() keeps already-inserted live text; drops only the uninserted buffer.
        textInserter.discard()
        sessionTranscript = ""
        endIndicatorSession(playSound: true)
        realtime.disconnect()
    }

    private func handleConnectionState(_ connection: RealtimeClient.ConnectionState) {
        switch connection {
        case .connected:
            if case .running = supervisor.state {
                if state != .listening && state != .flushing {
                    transition(to: .ready)
                    beginListeningIfPendingIntent()
                }
            }
        case .connecting:
            break
        case .disconnected:
            awaitingBufferClear = false
            if state == .listening {
                intent.interruptActiveSession()
                escapeHotKey.unregister()
                audio.stop()
                textInserter.discard()
                endIndicatorSession(playSound: true)
                transition(to: .starting)
            } else if state == .ready {
                transition(to: .starting)
            } else if state == .flushing {
                // Final may never arrive — recover to ready/starting.
                intent.clearAll()
                escapeHotKey.unregister()
                textInserter.discard()
                endIndicatorSession(playSound: true)
                transition(to: .starting)
            }
        }
    }

    private func handleDelta(_ delta: String) {
        guard !awaitingBufferClear else { return }
        guard state == .listening || state == .flushing else { return }
        sessionTranscript += delta
        print("[transcript delta] \(delta)")
        AppLog.general.info("delta: \(delta, privacy: .public)")
        // Stream mode types live; buffer mode accumulates until flush/done.
        textInserter.handleDelta(delta)
    }

    private func handleDone(_ transcript: String) {
        guard !awaitingBufferClear else { return }
        guard state == .listening || state == .flushing else { return }
        let finalText = transcript.isEmpty ? sessionTranscript : transcript
        print("[transcript done] \(finalText)")
        AppLog.general.info("done: \(finalText, privacy: .public)")
        sessionTranscript = ""

        if state == .flushing {
            // Buffer mode: insert the accumulated (sanitized) text once.
            // Stream mode: trailing deltas were already typed via handleDelta;
            // flush() is a no-op there. Any delta that arrived after commit
            // but before done was already routed through handleDelta.
            let inserted = textInserter.flush()
            if !inserted.isEmpty {
                AppLog.general.info(
                    "buffer flush inserted \(inserted.count, privacy: .public) chars"
                )
            }
            intent.clearAll()
            escapeHotKey.unregister()
            endIndicatorSession(playSound: true)
            // Return to ready if server+ws are still up.
            if realtime.isConnected, case .running = supervisor.state {
                transition(to: .ready)
            } else {
                transition(to: .starting)
            }
        }
    }

    private func transition(to newState: DictationState) {
        guard state != newState else { return }
        // Tear down Esc registration whenever we leave an active session.
        switch newState {
        case .listening, .flushing:
            break
        default:
            escapeHotKey.unregister()
        }
        state = newState
        AppLog.general.info("dictation → \(newState.statusTitle, privacy: .public)")
    }
}

// MARK: - App delegate / menu bar

/// Whether the running binary may register `SMAppService.mainApp`.
enum AppInstallationContext: Equatable, Sendable {
    /// Raw SwiftPM / `make run` executable (not inside a `.app`).
    case rawExecutable
    /// Packaged `.app` that is not under `/Applications`.
    case uninstalledBundle
    /// Packaged `.app` installed under `/Applications`.
    case installedBundle

    static func current(bundle: Bundle = .main) -> AppInstallationContext {
        let bundleURL = bundle.bundleURL
        guard bundleURL.pathExtension == "app" else {
            return .rawExecutable
        }
        let parent = bundleURL.deletingLastPathComponent().standardizedFileURL.path
        if parent == "/Applications" {
            return .installedBundle
        }
        return .uninstalledBundle
    }

    var canRegisterLaunchAtLogin: Bool {
        self == .installedBundle
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: DictationController!
    private var config: AppConfig = .load()
    private let micKeyManager = MicKeyManager()

    private var startStopItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var playSoundsItem: NSMenuItem!
    private var installRemapItem: NSMenuItem!
    private var removeRemapItem: NSMenuItem!
    private var micKeyModeItem: NSMenuItem!
    private var holdToTalkModeItem: NSMenuItem!
    private var pressToToggleModeItem: NSMenuItem!
    private var micPermissionItem: NSMenuItem!
    private var axPermissionItem: NSMenuItem!
    private var secureInputItem: NSMenuItem!
    private var serverStatusItem: NSMenuItem!
    private var showServerDetailsItem: NSMenuItem!
    private var retryServerItem: NSMenuItem!
    private var statusItemLabel: NSMenuItem!

    /// Interprets F13 press/release according to the latched mic-key mode.
    private var micKeyInterpreter = MicKeyGestureInterpreter()

    /// Dev toggle hotkey: ⌥⌘D (Option+Command+D).
    private let toggleHotKey = CarbonHotKey(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(cmdKey | optionKey),
        signature: OSType(0x4C444467), // LDDg
        id: 1
    )

    /// Mic-key path: F13 (after hidutil remap). Mode-dependent hold or toggle.
    private let f13HotKey = CarbonHotKey(
        keyCode: MicKeyManager.f13KeyCode,
        modifiers: 0,
        signature: OSType(0x4C444633), // LDF3
        id: 1
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Restore sound preference before any dictation can start.
        let defaults = AppIdentity.defaults
        if defaults.object(forKey: AppPrefs.playSoundsEnabled) == nil {
            defaults.set(true, forKey: AppPrefs.playSoundsEnabled)
        }
        IndicatorSounds.shared.enabled = defaults.bool(forKey: AppPrefs.playSoundsEnabled)

        controller = DictationController(config: config)
        controller.onStateChange = { [weak self] state in
            self?.refreshUI(for: state)
        }

        let toggleAction: () -> Void = { [weak self] in
            self?.controller.toggleDictation()
        }
        toggleHotKey.onPressed = toggleAction
        f13HotKey.onPressed = { [weak self] in
            self?.handleMicKeyPressed()
        }
        f13HotKey.onReleased = { [weak self] in
            self?.handleMicKeyReleased()
        }
        toggleHotKey.register()
        f13HotKey.register()
        AppLog.general.info("Hotkeys registered: ⌥⌘D (dev) + F13 (mic-key)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        applyMenuBarIcon(for: .idle)

        let menu = NSMenu()

        statusItemLabel = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusItemLabel.isEnabled = false
        menu.addItem(statusItemLabel)

        serverStatusItem = NSMenuItem(title: "Server: …", action: nil, keyEquivalent: "")
        serverStatusItem.isEnabled = false
        menu.addItem(serverStatusItem)

        showServerDetailsItem = NSMenuItem(
            title: "Show Server Details…",
            action: #selector(showServerDetails),
            keyEquivalent: ""
        )
        showServerDetailsItem.target = self
        showServerDetailsItem.isHidden = true
        menu.addItem(showServerDetailsItem)

        retryServerItem = NSMenuItem(
            title: "Retry Server",
            action: #selector(retryServer),
            keyEquivalent: ""
        )
        retryServerItem.target = self
        retryServerItem.isHidden = true
        menu.addItem(retryServerItem)

        menu.addItem(.separator())

        startStopItem = NSMenuItem(
            title: "Start Dictation",
            action: #selector(toggleDictation),
            keyEquivalent: ""
        )
        startStopItem.target = self
        menu.addItem(startStopItem)

        menu.addItem(.separator())

        installRemapItem = NSMenuItem(
            title: "Install mic-key remap…",
            action: #selector(installMicKeyRemap),
            keyEquivalent: ""
        )
        installRemapItem.target = self
        menu.addItem(installRemapItem)

        removeRemapItem = NSMenuItem(
            title: "Remove mic-key remap",
            action: #selector(removeMicKeyRemap),
            keyEquivalent: ""
        )
        removeRemapItem.target = self
        menu.addItem(removeRemapItem)

        let micKeyModeMenu = NSMenu()
        holdToTalkModeItem = NSMenuItem(
            title: MicKeyMode.holdToTalk.displayTitle,
            action: #selector(selectHoldToTalkMode),
            keyEquivalent: ""
        )
        holdToTalkModeItem.target = self
        micKeyModeMenu.addItem(holdToTalkModeItem)

        pressToToggleModeItem = NSMenuItem(
            title: MicKeyMode.toggle.displayTitle,
            action: #selector(selectPressToToggleMode),
            keyEquivalent: ""
        )
        pressToToggleModeItem.target = self
        micKeyModeMenu.addItem(pressToToggleModeItem)

        micKeyModeItem = NSMenuItem(title: "Mic Key Mode", action: nil, keyEquivalent: "")
        micKeyModeItem.submenu = micKeyModeMenu
        menu.addItem(micKeyModeItem)

        launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        playSoundsItem = NSMenuItem(
            title: "Play Sounds",
            action: #selector(togglePlaySounds),
            keyEquivalent: ""
        )
        playSoundsItem.target = self
        menu.addItem(playSoundsItem)

        menu.addItem(.separator())

        micPermissionItem = NSMenuItem(title: "Microphone: …", action: nil, keyEquivalent: "")
        micPermissionItem.isEnabled = false
        menu.addItem(micPermissionItem)

        axPermissionItem = NSMenuItem(
            title: "Accessibility: …",
            action: #selector(promptAccessibilityPermission),
            keyEquivalent: ""
        )
        axPermissionItem.target = self
        menu.addItem(axPermissionItem)

        secureInputItem = NSMenuItem(title: "Secure Input: …", action: nil, keyEquivalent: "")
        secureInputItem.isEnabled = false
        menu.addItem(secureInputItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        refreshPermissionRows()
        refreshLaunchAtLoginItem()
        refreshPlaySoundsItem()
        refreshMicKeyModeItems()
        refreshRemapItems()
        refreshUI(for: .idle)

        // Request mic access early so the permission row updates.
        Task { @MainActor in
            _ = await AudioCapture.requestMicrophoneAccess()
            self.refreshPermissionRows()
        }

        controller.bootstrap()
        runFirstRunChecksIfNeeded()
        AppLog.general.info("LocalDictation launched")
    }

    @objc private func toggleDictation() {
        controller.toggleDictation()
    }

    @objc private func installMicKeyRemap() {
        let result = micKeyManager.installRemap()
        switch result {
        case .installed:
            do {
                try micKeyManager.installLaunchAgent()
            } catch {
                AppLog.general.error(
                    "LaunchAgent install failed: \(error.localizedDescription, privacy: .public)"
                )
                let alert = NSAlert()
                alert.messageText = "Mic-key remap installed"
                alert.informativeText =
                    "The remap is active for this session, but the LaunchAgent could not be installed "
                    + "(\(error.localizedDescription)). It will not survive reboot until fixed."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                refreshRemapItems()
                return
            }
            let mode = MicKeyMode.read(from: AppIdentity.defaults)
            let micBehavior: String
            switch mode {
            case .holdToTalk:
                micBehavior = "Hold 🎤 to talk (release to stop)."
            case .toggle:
                micBehavior = "Press 🎤 to toggle dictation."
            }
            let alert = NSAlert()
            alert.messageText = "Mic-key remap installed"
            alert.informativeText =
                "The 🎤 key now sends F13 and will be re-applied at login. "
                + micBehavior
                + " ⌥⌘D remains a toggle shortcut."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .needsInputMonitoring(let guidance):
            let alert = NSAlert()
            alert.messageText = "Input Monitoring required"
            alert.informativeText = guidance.userGuidance
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Input Monitoring")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(guidance.settingsURL)
            }

        case .failed(let message):
            let alert = NSAlert()
            alert.messageText = "Mic-key remap failed"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        refreshRemapItems()
    }

    @objc private func removeMicKeyRemap() {
        do {
            try micKeyManager.removeRemap()
            try micKeyManager.removeLaunchAgent()
            let alert = NSAlert()
            alert.messageText = "Mic-key remap removed"
            alert.informativeText = "The 🎤 key is restored to system behavior."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not remove mic-key remap"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        refreshRemapItems()
    }

    @objc private func togglePlaySounds() {
        let enabled = !IndicatorSounds.shared.enabled
        IndicatorSounds.shared.enabled = enabled
        AppIdentity.defaults.set(enabled, forKey: AppPrefs.playSoundsEnabled)
        refreshPlaySoundsItem()
    }

    @objc private func selectHoldToTalkMode() {
        MicKeyMode.write(.holdToTalk, to: AppIdentity.defaults)
        refreshMicKeyModeItems()
    }

    @objc private func selectPressToToggleMode() {
        MicKeyMode.write(.toggle, to: AppIdentity.defaults)
        refreshMicKeyModeItems()
    }

    private func handleMicKeyPressed() {
        let mode = MicKeyMode.read(from: AppIdentity.defaults)
        switch micKeyInterpreter.keyDown(mode: mode) {
        case .beginHold:
            controller.beginHoldDictation()
        case .toggle:
            controller.toggleDictation()
        case .endHold, .none:
            break
        }
    }

    private func handleMicKeyReleased() {
        guard micKeyInterpreter.keyUp() == .endHold else { return }
        controller.endHoldDictation()
    }

    @objc private func promptAccessibilityPermission() {
        if AXIsProcessTrusted() {
            refreshPermissionRows()
            return
        }
        // String key avoids Swift 6 concurrency complaint on the global CFStringRef var.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        let alert = NSAlert()
        alert.messageText = "Accessibility permission"
        alert.informativeText =
            "Local Dictation needs Accessibility to locate the caret and insert text. "
            + "Enable it in System Settings → Privacy & Security → Accessibility, then reopen the app if needed."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
        refreshPermissionRows()
    }

    @objc private func toggleLaunchAtLogin() {
        let context = AppInstallationContext.current()
        guard context.canRegisterLaunchAtLogin else {
            presentLaunchAtLoginInstallGuidance()
            refreshLaunchAtLoginItem()
            return
        }

        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .notRegistered:
                try service.register()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notFound:
                presentLaunchAtLoginAlert(
                    message: "Launch at Login is unavailable",
                    informative:
                        "macOS could not find this app’s login-item registration. Reinstall Local Dictation into /Applications, relaunch that copy, and try again."
                )
            @unknown default:
                presentLaunchAtLoginAlert(
                    message: "Launch at Login",
                    informative: "Unexpected login-item status. Open System Settings → General → Login Items and check Local Dictation there."
                )
            }
        } catch {
            AppLog.general.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
            presentLaunchAtLoginAlert(
                message: "Launch at Login",
                informative: "Couldn't update login item: \(error.localizedDescription)"
            )
        }
        refreshLaunchAtLoginItem()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLaunchAtLoginItem()
        refreshPermissionRows()
        refreshRemapItems()
        refreshPlaySoundsItem()
        refreshMicKeyModeItems()
    }

    private func presentLaunchAtLoginInstallGuidance() {
        presentLaunchAtLoginAlert(
            message: "Install in /Applications first",
            informative:
                "Launch at Login only works from Local Dictation installed under /Applications. Copy LocalDictation.app there, open that copy, then enable Launch at Login."
        )
    }

    private func presentLaunchAtLoginAlert(message: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quitApp() {
        toggleHotKey.unregister()
        f13HotKey.unregister()
        micKeyInterpreter.reset()
        controller.cancelDictation()
        NSApp.terminate(nil)
    }

    private func runFirstRunChecksIfNeeded() {
        let defaults = AppIdentity.defaults
        guard !defaults.bool(forKey: AppPrefs.firstRunChecksCompleted) else { return }
        defaults.set(true, forKey: AppPrefs.firstRunChecksCompleted)

        let report = FirstRunChecks.evaluate()
        guard report.needsUserAttention else { return }

        let alert = NSAlert()
        alert.messageText = "Turn off system Dictation / Siri shortcuts"
        var lines: [String] = [
            "So the 🎤 key reaches Local Dictation instead of macOS:",
            "",
        ]
        switch report.dictationShortcut {
        case .enabled:
            lines.append("• Keyboard → Dictation → Shortcut appears enabled — set it to Off.")
        case .unknown:
            lines.append("• Keyboard → Dictation → Shortcut — confirm it is Off.")
        case .disabled:
            break
        }
        switch report.siriHoldF5 {
        case .enabled, .unknown:
            lines.append(
                "• Apple Intelligence & Siri — turn off press-and-hold for Siri if it uses F5 / the mic key."
            )
        case .disabled:
            break
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Dictation Settings")
        alert.addButton(withTitle: "Open Siri Settings")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            FirstRunChecks.openDictationSettings()
        case .alertSecondButtonReturn:
            FirstRunChecks.openSiriSettings()
        default:
            break
        }
    }

    @objc private func showServerDetails() {
        guard let details = DictationPresentation.detailsText(for: controller.state) else { return }
        let alert = NSAlert()
        alert.messageText = "Server Details"
        alert.informativeText = details
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy Details")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(details, forType: .string)
        }
    }

    @objc private func retryServer() {
        controller.retryServer()
    }

    private func refreshUI(for state: DictationState) {
        applyMenuBarIcon(for: state)
        // Keep the menu-bar title concise — never put long diagnostics there.
        statusItemLabel.title = "Status: \(state.statusTitle)"

        switch state {
        case .listening:
            startStopItem.title = "Stop Dictation"
            startStopItem.isEnabled = true
        case .ready, .idle, .failed:
            startStopItem.title = "Start Dictation"
            startStopItem.isEnabled = true
        case .starting, .downloading, .flushing, .restarting:
            startStopItem.title = "Start Dictation"
            startStopItem.isEnabled = false
        }

        refreshServerStatusRow(for: state)
        refreshServerActionItems(for: state)
        refreshPermissionRows()
    }

    private func refreshServerActionItems(for state: DictationState) {
        showServerDetailsItem.isHidden = !DictationPresentation.showsServerDetails(for: state)
        retryServerItem.isHidden = !DictationPresentation.showsRetryServer(for: state)
    }

    /// Idle: flattened bitmap template so AppKit tints like system menu-bar
    /// icons (raw SF Symbol `isTemplate` stays black on a dark/fullscreen bar).
    /// Colored states: solid painted glyph.
    private func applyMenuBarIcon(for state: DictationState) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil
        if let tint = state.menuBarTint {
            button.image = Self.menuBarMicImage(color: tint, template: false)
        } else {
            button.image = Self.menuBarMicImage(color: .black, template: true)
        }
    }

    private static func menuBarMicImage(color: NSColor, template: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(.preferringMonochrome())
        let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Local Dictation")?
            .withSymbolConfiguration(config)
        let size = NSSize(width: 18, height: 18)
        let ink = template ? NSColor.black : color
        let image = NSImage(size: size, flipped: false) { rect in
            guard let symbol else { return false }
            let drawSize = symbol.size
            let origin = NSPoint(
                x: (rect.width - drawSize.width) / 2,
                y: (rect.height - drawSize.height) / 2
            )
            symbol.draw(
                in: NSRect(origin: origin, size: drawSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            // Flatten hierarchical SF Symbol layers into a single ink color
            // without per-pixel NSColor reads (those spam colorspace -1).
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.setBlendMode(.sourceIn)
                ctx.setFillColor(ink.cgColor)
                ctx.fill(rect)
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    private func refreshServerStatusRow(for state: DictationState) {
        serverStatusItem.title = DictationPresentation.serverRowTitle(for: state)
    }

    private func refreshPermissionRows() {
        let micStatus = AudioCapture.microphoneAuthorizationStatus()
        let micText: String
        switch micStatus {
        case .authorized:
            micText = "Microphone: Granted"
        case .denied:
            micText = "Microphone: Denied"
        case .restricted:
            micText = "Microphone: Restricted"
        case .notDetermined:
            micText = "Microphone: Not determined"
        @unknown default:
            micText = "Microphone: Unknown"
        }
        micPermissionItem.title = micText

        let trusted = AXIsProcessTrusted()
        if trusted {
            axPermissionItem.title = "Accessibility: Granted"
            axPermissionItem.isEnabled = false
            axPermissionItem.action = nil
        } else {
            axPermissionItem.title = "Accessibility: Not granted — click to grant…"
            axPermissionItem.isEnabled = true
            axPermissionItem.action = #selector(promptAccessibilityPermission)
            axPermissionItem.target = self
        }

        let secure = TextInserter.isSecureEventInputEnabled()
        if secure {
            secureInputItem.title = "Secure Input: Active (dictation blocked)"
        } else {
            secureInputItem.title = "Secure Input: Off"
        }
    }

    private func refreshLaunchAtLoginItem() {
        let context = AppInstallationContext.current()
        guard context.canRegisterLaunchAtLogin else {
            launchAtLoginItem.title = "Launch at Login (install in /Applications first)"
            launchAtLoginItem.state = .off
            launchAtLoginItem.isEnabled = true
            return
        }

        launchAtLoginItem.isEnabled = true
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginItem.title = "Launch at Login"
            launchAtLoginItem.state = .on
        case .notRegistered:
            launchAtLoginItem.title = "Launch at Login"
            launchAtLoginItem.state = .off
        case .requiresApproval:
            launchAtLoginItem.title = "Launch at Login (approval required…)"
            launchAtLoginItem.state = .mixed
        case .notFound:
            launchAtLoginItem.title = "Launch at Login (unavailable)"
            launchAtLoginItem.state = .off
        @unknown default:
            launchAtLoginItem.title = "Launch at Login"
            launchAtLoginItem.state = .off
        }
    }

    private func refreshPlaySoundsItem() {
        playSoundsItem.state = IndicatorSounds.shared.enabled ? .on : .off
    }

    private func refreshMicKeyModeItems() {
        let mode = MicKeyMode.read(from: AppIdentity.defaults)
        holdToTalkModeItem.state = mode == .holdToTalk ? .on : .off
        pressToToggleModeItem.state = mode == .toggle ? .on : .off
    }

    private func refreshRemapItems() {
        let remapped = micKeyManager.verifyRemap()
        let agent = micKeyManager.isLaunchAgentInstalled()
        installRemapItem.title = (remapped && agent)
            ? "Reinstall mic-key remap…"
            : "Install mic-key remap…"
        removeRemapItem.isEnabled = remapped || agent
    }
}

// MARK: - Carbon hotkey helper

/// Thin wrapper around `RegisterEventHotKey`, with one shared `InstallEventHandler`
/// for the process. Carbon treats (handlerProc, userData) as a unique signature on a
/// target — installing the same proc with `nil` userData twice yields
/// `eventHandlerAlreadyInstalledErr` (-9866), so every hotkey must share one handler
/// and dispatch via `targets[(signature, id)]`.
/// Sole hotkey mechanism for the app (⌥⌘D, F13, Esc).
@MainActor
final class CarbonHotKey {
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let signature: OSType
    private let id: UInt32
    private var edgeLatch = HotKeyEdgeLatch()

    private var hotKeyRef: EventHotKeyRef?
    private var isRegistered = false

    /// Targets looked up from the shared C callback. One slot per (signature, id).
    private nonisolated(unsafe) static var targets: [UInt64: CarbonHotKey] = [:]
    /// Single app-target handler; installed on first register, removed when empty.
    private nonisolated(unsafe) static var sharedHandlerRef: EventHandlerRef?
    private nonisolated(unsafe) static var sharedHandlerInstallFailed = false

    private var targetKey: UInt64 {
        (UInt64(signature) << 32) | UInt64(id)
    }

    init(keyCode: UInt32, modifiers: UInt32, signature: OSType, id: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.signature = signature
        self.id = id
    }

    deinit {
        // Teardown is driven by explicit unregister(); Carbon refs are not
        // Sendable so we cannot touch them from a nonisolated deinit (Swift 6).
    }

    @discardableResult
    func register() -> Bool {
        guard !isRegistered else { return true }
        guard Self.ensureSharedHandler() else { return false }

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            AppLog.general.error(
                "RegisterEventHotKey failed OSStatus=\(registerStatus, privacy: .public)"
            )
            hotKeyRef = nil
            return false
        }

        Self.targets[targetKey] = self
        isRegistered = true
        return true
    }

    func unregister() {
        guard isRegistered || hotKeyRef != nil else { return }
        cleanup()
    }

    private func cleanup() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        edgeLatch.reset()
        Self.targets.removeValue(forKey: targetKey)
        isRegistered = false
        Self.tearDownSharedHandlerIfUnused()
    }

    /// Installs one shared handler for pressed + released on the application target.
    private static func ensureSharedHandler() -> Bool {
        if sharedHandlerRef != nil { return true }
        if sharedHandlerInstallFailed { return false }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ in
                guard let eventRef else { return OSStatus(eventNotHandledErr) }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else {
                    return OSStatus(eventNotHandledErr)
                }

                let lookup = (UInt64(hotKeyID.signature) << 32) | UInt64(hotKeyID.id)
                guard let target = CarbonHotKey.targets[lookup] else {
                    return OSStatus(eventNotHandledErr)
                }

                let kind = GetEventKind(eventRef)
                DispatchQueue.main.async {
                    if kind == UInt32(kEventHotKeyPressed) {
                        guard target.edgeLatch.pressed() else { return }
                        target.onPressed?()
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        guard target.edgeLatch.released() else { return }
                        target.onReleased?()
                    }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            nil,
            &handlerRef
        )

        guard installStatus == noErr, let handlerRef else {
            sharedHandlerInstallFailed = true
            AppLog.general.error(
                "InstallEventHandler failed OSStatus=\(installStatus, privacy: .public)"
            )
            return false
        }

        sharedHandlerRef = handlerRef
        return true
    }

    private static func tearDownSharedHandlerIfUnused() {
        guard targets.isEmpty, let handlerRef = sharedHandlerRef else { return }
        RemoveEventHandler(handlerRef)
        sharedHandlerRef = nil
        sharedHandlerInstallFailed = false
    }
}

/// Entry point used by the thin `LocalDictationApp` executable target.
@MainActor
public enum LocalDictationBootstrap {
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
