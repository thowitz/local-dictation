import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Foundation
import ServiceManagement
import os

// MARK: - Dictation state machine

enum DictationState: Equatable, Sendable {
    case idle
    case starting
    case downloading(percent: Int?)
    case ready
    case listening
    case flushing
    case error(String)

    /// Nil → flattened template bitmap (tracks menu-bar light/dark). Colored
    /// only for transient / active states. Raw SF Symbol `isTemplate` stays
    /// black on a dark/fullscreen bar, so idle/ready must be flattened first.
    var menuBarTint: NSColor? {
        switch self {
        case .idle, .ready:
            return nil
        case .starting, .downloading:
            return .systemOrange
        case .listening:
            return .systemBlue
        case .flushing:
            return .systemPurple
        case .error:
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
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

// MARK: - Persisted prefs

private enum AppPrefs {
    static let firstRunChecksCompleted = "firstRunChecksCompleted"
    static let playSoundsEnabled = "playSoundsEnabled"
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
    private var wantsListening = false
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
                            self?.endIndicatorSession(playSound: true)
                            self?.transition(to: .error(message))
                        }
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
        case .ready, .idle, .error:
            startDictation()
        default:
            break
        }
    }

    func startDictation() {
        if TextInserter.isSecureEventInputEnabled() {
            wantsListening = false
            let message = "Secure input is enabled — dictation refused."
            AppLog.general.error("\(message, privacy: .public)")
            transition(to: .error(message))
            return
        }

        if !AXIsProcessTrusted() {
            wantsListening = false
            let message = "Accessibility permission required — grant it in System Settings."
            AppLog.general.error("\(message, privacy: .public)")
            transition(to: .error(message))
            return
        }

        switch state {
        case .ready:
            break
        case .listening, .flushing, .starting, .downloading:
            return
        case .idle, .error:
            // Kick the server if needed, then wait for ready.
            wantsListening = true
            if case .idle = state {
                transition(to: .starting)
                supervisor.start()
            }
            return
        }

        wantsListening = true
        beginListening()
    }

    func stopDictation() {
        guard state == .listening else { return }
        wantsListening = false
        // Keep Esc armed through flushing so cancel still works mid-flush.
        transition(to: .flushing)
        updateIndicatorProcessing()
        audio.stop()
        realtime.commitFinal()
        AppLog.general.info("Stop dictation — commit final sent")
    }

    /// Esc while active: stop immediately with no flush wait. Already-typed
    /// stream text stays; buffer-mode buffer is discarded.
    func cancelDictation() {
        guard state == .listening || state == .flushing else { return }
        wantsListening = false
        escapeHotKey.unregister()
        audio.stop()
        textInserter.discard()
        sessionTranscript = ""
        endIndicatorSession(playSound: true)
        // Reset server-side session without waiting for a final transcript.
        realtime.clearBuffer()
        AppLog.general.info("Dictation cancelled (Esc) — no flush")

        if realtime.isConnected, case .running = supervisor.state {
            transition(to: .ready)
        } else {
            transition(to: .starting)
        }
    }

    // MARK: - Internals

    private func beginListening() {
        guard state == .ready || state == .listening else { return }

        if TextInserter.isSecureEventInputEnabled() {
            wantsListening = false
            let message = "Secure input is enabled — dictation refused (synthetic keys are dropped)."
            AppLog.general.error("\(message, privacy: .public)")
            transition(to: .error(message))
            return
        }

        if !AXIsProcessTrusted() {
            wantsListening = false
            let message = "Accessibility permission required — grant it in System Settings."
            AppLog.general.error("\(message, privacy: .public)")
            transition(to: .error(message))
            return
        }

        // Clear any leftover buffer from a previous session.
        realtime.clearBuffer()
        sessionTranscript = ""
        textInserter.beginSession()

        do {
            try audio.start { [weak self] chunk in
                self?.realtime.sendAudio(chunk)
            }
        } catch {
            textInserter.discard()
            transition(to: .error(error.localizedDescription))
            return
        }

        escapeHotKey.register()
        showIndicatorListening()
        transition(to: .listening)
        AppLog.general.info(
            "Dictation started — mode=\(self.textInserter.mode.rawValue, privacy: .public)"
        )
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

    private func handleServerState(_ serverState: ServerSupervisor.State) {
        switch serverState {
        case .idle, .stopped:
            if state != .idle {
                escapeHotKey.unregister()
                audio.stop()
                textInserter.discard()
                endIndicatorSession(playSound: state == .listening || state == .flushing)
                realtime.disconnect()
                transition(to: .idle)
            }

        case .launching, .waitingForReady, .restarting:
            if state != .listening && state != .flushing {
                transition(to: .starting)
            }

        case .downloading(let percent):
            if state != .listening && state != .flushing {
                transition(to: .downloading(percent: percent))
            }

        case .running:
            // Open (or keep) the persistent WebSocket once the server is healthy.
            if !realtime.isConnected {
                realtime.connect()
            } else if state != .listening && state != .flushing {
                transition(to: .ready)
                if wantsListening {
                    beginListening()
                }
            }

        case .failed(let message):
            escapeHotKey.unregister()
            audio.stop()
            textInserter.discard()
            endIndicatorSession(playSound: state == .listening || state == .flushing)
            realtime.disconnect()
            transition(to: .error(message))
        }
    }

    private func handleConnectionState(_ connection: RealtimeClient.ConnectionState) {
        switch connection {
        case .connected:
            if case .running = supervisor.state {
                if state != .listening && state != .flushing {
                    transition(to: .ready)
                    if wantsListening {
                        beginListening()
                    }
                }
            }
        case .connecting:
            break
        case .disconnected:
            if state == .listening {
                escapeHotKey.unregister()
                audio.stop()
                textInserter.discard()
                endIndicatorSession(playSound: true)
                transition(to: .starting)
            } else if state == .ready {
                transition(to: .starting)
            } else if state == .flushing {
                // Final may never arrive — recover to ready/starting.
                escapeHotKey.unregister()
                textInserter.discard()
                endIndicatorSession(playSound: true)
                transition(to: .starting)
            }
        }
    }

    private func handleDelta(_ delta: String) {
        sessionTranscript += delta
        print("[transcript delta] \(delta)")
        AppLog.general.info("delta: \(delta, privacy: .public)")
        // Stream mode types live; buffer mode accumulates until flush/done.
        textInserter.handleDelta(delta)
    }

    private func handleDone(_ transcript: String) {
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
            wantsListening = false
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controller: DictationController!
    private var config: AppConfig = .load()
    private let micKeyManager = MicKeyManager()

    private var startStopItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var playSoundsItem: NSMenuItem!
    private var installRemapItem: NSMenuItem!
    private var removeRemapItem: NSMenuItem!
    private var micPermissionItem: NSMenuItem!
    private var axPermissionItem: NSMenuItem!
    private var secureInputItem: NSMenuItem!
    private var serverStatusItem: NSMenuItem!
    private var statusItemLabel: NSMenuItem!

    /// Dev toggle hotkey: ⌥⌘D (Option+Command+D).
    private let toggleHotKey = CarbonHotKey(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(cmdKey | optionKey),
        signature: OSType(0x4C444467), // LDDg
        id: 1
    )

    /// Mic-key path: F13 (after hidutil remap). Same toggle action as ⌥⌘D.
    private let f13HotKey = CarbonHotKey(
        keyCode: MicKeyManager.f13KeyCode,
        modifiers: 0,
        signature: OSType(0x4C444633), // LDF3
        id: 1
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Restore sound preference before any dictation can start.
        let defaults = UserDefaults.standard
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
        f13HotKey.onPressed = toggleAction
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

        statusItem.menu = menu
        refreshPermissionRows()
        refreshLaunchAtLoginItem()
        refreshPlaySoundsItem()
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
            let alert = NSAlert()
            alert.messageText = "Mic-key remap installed"
            alert.informativeText =
                "The 🎤 key now sends F13 and will be re-applied at login. "
                + "Press 🎤 (or ⌥⌘D) to toggle dictation."
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
        UserDefaults.standard.set(enabled, forKey: AppPrefs.playSoundsEnabled)
        refreshPlaySoundsItem()
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
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            AppLog.general.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Launch at Login"
            alert.informativeText =
                "Couldn't update login item: \(error.localizedDescription)\n\nNote: SMAppService.mainApp requires a bundled .app; it may not work when running the raw SPM executable."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        refreshLaunchAtLoginItem()
    }

    @objc private func quitApp() {
        toggleHotKey.unregister()
        f13HotKey.unregister()
        controller.cancelDictation()
        NSApp.terminate(nil)
    }

    private func runFirstRunChecksIfNeeded() {
        let defaults = UserDefaults.standard
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

    private func refreshUI(for state: DictationState) {
        applyMenuBarIcon(for: state)
        statusItemLabel.title = "Status: \(state.statusTitle)"

        switch state {
        case .listening:
            startStopItem.title = "Stop Dictation"
            startStopItem.isEnabled = true
        case .ready, .idle, .error:
            startStopItem.title = "Start Dictation"
            startStopItem.isEnabled = true
        case .starting, .downloading, .flushing:
            startStopItem.title = "Start Dictation"
            startStopItem.isEnabled = false
        }

        refreshServerStatusRow(for: state)
        refreshPermissionRows()
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
        switch state {
        case .downloading(let percent):
            if let percent {
                serverStatusItem.title = "Server: Downloading model… \(percent)%"
            } else {
                serverStatusItem.title = "Server: Downloading model…"
            }
        case .starting:
            serverStatusItem.title = "Server: Starting / reconnecting…"
        case .ready, .listening, .flushing:
            serverStatusItem.title = "Server: Running"
        case .idle:
            serverStatusItem.title = "Server: Stopped"
        case .error(let message):
            if message.localizedCaseInsensitiveContains("secure input") {
                serverStatusItem.title = "Server: Running"
            } else if message.localizedCaseInsensitiveContains("accessibility") {
                serverStatusItem.title = "Server: —"
            } else {
                serverStatusItem.title = "Server: Error / restarting"
            }
        }
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
        let enabled = SMAppService.mainApp.status == .enabled
        launchAtLoginItem.state = enabled ? .on : .off
    }

    private func refreshPlaySoundsItem() {
        playSoundsItem.state = IndicatorSounds.shared.enabled ? .on : .off
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

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let signature: OSType
    private let id: UInt32

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
        Self.targets.removeValue(forKey: targetKey)
        isRegistered = false
        Self.tearDownSharedHandlerIfUnused()
    }

    /// Installs one `kEventHotKeyPressed` handler on the application target.
    private static func ensureSharedHandler() -> Bool {
        if sharedHandlerRef != nil { return true }
        if sharedHandlerInstallFailed { return false }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
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

                DispatchQueue.main.async {
                    target.onPressed?()
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

@main
enum LocalDictationMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
