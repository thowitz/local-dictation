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
    case unloading
    case restarting(ServerRestartStatus)
    case failed(DictationFailure)

    /// Nil → flattened template bitmap (tracks menu-bar light/dark). Colored
    /// only for transient / active states. Raw SF Symbol `isTemplate` stays
    /// black on a dark/fullscreen bar, so idle/ready must be flattened first.
    var menuBarTint: NSColor? {
        switch self {
        case .idle, .ready:
            return nil
        case .starting, .downloading, .restarting, .unloading:
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
            return "Dormant"
        case .starting:
            return "Warming up…"
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
        case .unloading:
            return "Unloading…"
        case .restarting(let status):
            return status.menuSummary
        case .failed(let failure):
            return failure.menuSummary
        }
    }
}

// MARK: - Persisted prefs

private enum AppPrefs {
    /// Legacy key retained for migration awareness; must not satisfy setup completion.
    static let firstRunChecksCompleted = "firstRunChecksCompleted"
    static let playSoundsEnabled = "playSoundsEnabled"
    static let micKeyMode = MicKeyMode.preferenceKey
}

// MARK: - Controller

@MainActor
final class DictationController {
    /// Injectable seams for lifecycle tests (permissions, audio, clock).
    struct Dependencies {
        var sleep: (Duration) async throws -> Void
        var isSecureEventInputEnabled: () -> Bool
        var isAccessibilityTrusted: () -> Bool
        var startAudio: ((@escaping @Sendable (Data) -> Void) throws -> Void)?
        var stopAudio: (() -> Void)?
        /// When false, skip AppKit indicator / Esc hotkey side effects (unit tests).
        var presentsSessionUI: Bool

        @MainActor
        static func production() -> Dependencies {
            Dependencies(
                sleep: { try await Task.sleep(for: $0) },
                isSecureEventInputEnabled: { TextInserter.isSecureEventInputEnabled() },
                isAccessibilityTrusted: { AXIsProcessTrusted() },
                startAudio: nil,
                stopAudio: nil,
                presentsSessionUI: true
            )
        }
    }

    private(set) var state: DictationState = .idle {
        didSet {
            onStateChange?(state)
        }
    }

    var onStateChange: ((DictationState) -> Void)?

    private let config: AppConfig
    private let deps: Dependencies
    private let supervisor: any SpeechRuntime
    private let realtime: any DictationRealtimeClient
    private let idleScheduler: IdleUnloadScheduler
    private let audio = AudioCapture()
    private let textInserter = TextInserter()
    private let indicator = IndicatorPanel()
    private let sounds = IndicatorSounds.shared
    private let escapeHotKey = CarbonHotKey(
        keyCode: UInt32(kVK_Escape),
        modifiers: 0,
        signature: OSType(0x4C444573), // LDEs
        id: 1,
        requiresReleaseToRearm: false
    )

    private var sessionTranscript = ""
    private var intent = DictationIntentTracker()
    private var cancellationBarrier = CancellationBarrier()
    private var indicatorActive = false
    private var didShutdown = false

    /// Test seam: whether the idle unload deadline is currently armed.
    var isIdleSchedulerArmed: Bool { idleScheduler.isArmed }

    /// Test seam: underlying speech runtime (Voxtral supervisor or Parakeet).
    var speechRuntime: any SpeechRuntime { supervisor }

    convenience init(config: AppConfig) {
        self.init(config: config, dependencies: .production())
    }

    init(
        config: AppConfig,
        dependencies: Dependencies,
        supervisor: (any SpeechRuntime)? = nil,
        realtime: (any DictationRealtimeClient)? = nil
    ) {
        self.config = config
        self.deps = dependencies

        // Production wiring: pick Voxtral (Python WS) or Parakeet (in-process CoreML).
        // Tests inject both seams explicitly.
        if let supervisor, let realtime {
            self.supervisor = supervisor
            self.realtime = realtime
        } else if let supervisor {
            self.supervisor = supervisor
            self.realtime = realtime ?? Self.makeRealtimeClient(config: config, sharedEngine: nil)
        } else if let realtime {
            self.supervisor = Self.makeSpeechRuntime(config: config, sharedEngine: nil)
            self.realtime = realtime
        } else {
            let pair = Self.makeProviderPair(config: config)
            self.supervisor = pair.runtime
            self.realtime = pair.client
        }

        self.idleScheduler = IdleUnloadScheduler(
            timeout: config.idleUnloadTimeout,
            sleep: dependencies.sleep
        )

        escapeHotKey.onPressed = { [weak self] in
            self?.cancelDictation()
        }

        let priorHandler = self.supervisor.onStateChange
        self.supervisor.onStateChange = { [weak self] serverState in
            priorHandler?(serverState)
            Task { @MainActor in
                self?.handleServerState(serverState)
            }
        }

        self.realtime.setCallbacks(
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
                        if self?.state == .listening || self?.state == .flushing {
                            self?.intent.clearAll()
                            self?.cancellationBarrier.reset()
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

    /// Builds a matched runtime + client pair for the configured provider.
    private static func makeProviderPair(
        config: AppConfig
    ) -> (runtime: any SpeechRuntime, client: any DictationRealtimeClient) {
        switch config.provider {
        case .voxtral:
            return (ServerSupervisor(config: config), RealtimeClient(endpoint: config.websocketURL))
        case .parakeet:
            let engine = ParakeetEngine()
            return (ParakeetRuntime(config: config, engine: engine), ParakeetRealtimeClient(engine: engine))
        }
    }

    private static func makeSpeechRuntime(
        config: AppConfig,
        sharedEngine: ParakeetEngine?
    ) -> any SpeechRuntime {
        switch config.provider {
        case .voxtral:
            return ServerSupervisor(config: config)
        case .parakeet:
            return ParakeetRuntime(config: config, engine: sharedEngine ?? ParakeetEngine())
        }
    }

    private static func makeRealtimeClient(
        config: AppConfig,
        sharedEngine: ParakeetEngine?
    ) -> any DictationRealtimeClient {
        switch config.provider {
        case .voxtral:
            return RealtimeClient(endpoint: config.websocketURL)
        case .parakeet:
            return ParakeetRealtimeClient(engine: sharedEngine ?? ParakeetEngine())
        }
    }

    func bootstrap() {
        transition(to: .starting)
        supervisor.start()
    }

    /// Idempotent teardown for Quit / `applicationWillTerminate`.
    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        idleScheduler.cancel()
        intent.clearAll()
        cancellationBarrier.reset()
        escapeHotKey.unregister()
        stopAudioCapture()
        textInserter.discard()
        sessionTranscript = ""
        endIndicatorSession(playSound: false)
        realtime.disconnect()
        supervisor.stop(reason: .applicationQuit)
    }

    /// Toggle: start when idle/ready; commit+flush when listening.
    func toggleDictation() {
        switch state {
        case .listening:
            stopDictation()
        case .ready, .idle, .failed, .unloading:
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
            armIdleSchedulerIfEligible()
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
        idleScheduler.cancel()

        switch state {
        case .starting, .downloading, .restarting, .unloading:
            if startIntent == .micHold {
                if deps.isSecureEventInputEnabled() || !deps.isAccessibilityTrusted() {
                    intent.clearAll()
                    return
                }
                intent.queue(.micHold)
                if state == .unloading {
                    transition(to: .starting)
                    supervisor.start()
                }
            } else if state == .unloading {
                intent.queue(startIntent)
                transition(to: .starting)
                supervisor.start()
            } else if startIntent == .manualToggle {
                intent.queue(startIntent)
            }
            return
        case .listening, .flushing:
            return
        case .ready, .idle, .failed:
            break
        }

        if deps.isSecureEventInputEnabled() {
            intent.clearAll()
            let message = "Secure input is enabled — dictation refused."
            AppLog.general.error("\(message, privacy: .public)")
            transition(to: .failed(.secureInput(message)))
            return
        }

        if !deps.isAccessibilityTrusted() {
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
        case .idle, .failed:
            intent.queue(startIntent)
            switch state {
            case .idle:
                transition(to: .starting)
                supervisor.start()
            case .failed(.server):
                transition(to: .starting)
                supervisor.retry()
            default:
                break
            }
        default:
            break
        }
    }

    func stopDictation() {
        guard state == .listening else { return }
        intent.clearAll()
        transition(to: .flushing)
        updateIndicatorProcessing()
        stopAudioCapture()
        if !realtime.commitFinal() {
            AppLog.general.error("commitFinal enqueue failed — tearing down locally")
            escapeHotKey.unregister()
            textInserter.discard()
            sessionTranscript = ""
            endIndicatorSession(playSound: true)
            if realtime.isConnected, case .running = supervisor.state {
                transition(to: .ready)
                resetIdleSchedulerAfterSession()
            } else {
                transition(to: .starting)
            }
            return
        }
        AppLog.general.info("Stop dictation — commit final sent")
    }

    /// Esc while active: stop immediately with no flush wait.
    func cancelDictation() {
        guard state == .listening || state == .flushing else { return }
        intent.clearAll()
        escapeHotKey.unregister()
        stopAudioCapture()
        textInserter.discard()
        sessionTranscript = ""
        endIndicatorSession(playSound: true)

        cancellationBarrier.beginCancel()
        if !realtime.clearBuffer() {
            cancellationBarrier.clearEnqueueFailed()
            AppLog.general.info("Dictation cancelled (Esc) — clear enqueue failed, relying on reconnect")
        } else {
            AppLog.general.info("Dictation cancelled (Esc) — awaiting buffer clear")
        }

        if realtime.isConnected, case .running = supervisor.state {
            transition(to: .ready)
            resetIdleSchedulerAfterSession()
        } else {
            transition(to: .starting)
        }
    }

    // MARK: - Idle unload

    private func armIdleSchedulerIfEligible() {
        guard !didShutdown else { return }
        guard state == .ready else { return }
        guard case .running = supervisor.state, realtime.isConnected else { return }
        guard intent.pending == nil, intent.active == nil else { return }
        idleScheduler.ensureArmed { [weak self] in
            self?.handleIdleTimeout()
        }
    }

    private func resetIdleSchedulerAfterSession() {
        guard !didShutdown else { return }
        guard state == .ready else { return }
        guard case .running = supervisor.state, realtime.isConnected else { return }
        guard intent.pending == nil, intent.active == nil else { return }
        idleScheduler.reset { [weak self] in
            self?.handleIdleTimeout()
        }
    }

    private func handleIdleTimeout() {
        guard !didShutdown else { return }
        guard intent.pending == nil, intent.active == nil else {
            AppLog.general.info("Idle unload skipped — dictation request still pending/active")
            return
        }
        guard state != .listening, state != .flushing else {
            AppLog.general.info("Idle unload skipped — session still active")
            return
        }
        // Unload while the runtime is still resident even if the socket is mid-reconnect
        // (`.starting` after an idle drop). Do not require `.ready`.
        guard supervisor.desiredRunning, case .running = supervisor.state else { return }
        guard state != .unloading, state != .idle else { return }

        AppLog.general.info("Idle unload — disconnecting socket then stopping supervisor")
        transition(to: .unloading)
        realtime.disconnect()
        supervisor.stop(reason: .idleTimeout)
    }

    // MARK: - Internals

    private func beginListening() {
        guard state == .ready else { return }
        guard cancellationBarrier.shouldAllowStart(hasPendingIntent: intent.shouldBeginOnReadiness)
        else { return }
        guard case .running = supervisor.state, realtime.isConnected else { return }

        if deps.isSecureEventInputEnabled() {
            intent.clearAll()
            let message = "Secure input is enabled — dictation refused (synthetic keys are dropped)."
            AppLog.general.error("\(message, privacy: .public)")
            transition(to: .failed(.secureInput(message)))
            return
        }

        if !deps.isAccessibilityTrusted() {
            intent.clearAll()
            let message = "Accessibility permission required — grant it in System Settings."
            AppLog.general.error("\(message, privacy: .public)")
            transition(to: .failed(.accessibility(message)))
            return
        }

        sessionTranscript = ""
        textInserter.beginSession()

        do {
            let sendAudio: @Sendable (Data) -> Void = { [weak self] chunk in
                Task { @MainActor in
                    self?.realtime.sendAudio(chunk)
                }
            }
            try startAudioCapture(sendAudio)
        } catch {
            intent.clearAll()
            textInserter.discard()
            transition(to: .failed(.app(error.localizedDescription)))
            return
        }

        intent.activatePending()
        idleScheduler.cancel()
        if deps.presentsSessionUI {
            escapeHotKey.register()
            showIndicatorListening()
        }
        transition(to: .listening)
        AppLog.general.info(
            "Dictation started — mode=\(self.textInserter.mode.rawValue, privacy: .public)"
        )
    }

    private func beginListeningIfPendingIntent() {
        guard cancellationBarrier.shouldAllowStart(hasPendingIntent: intent.shouldBeginOnReadiness)
        else {
            armIdleSchedulerIfEligible()
            return
        }
        guard case .running = supervisor.state, realtime.isConnected else { return }
        beginListening()
    }

    private func handleBufferCleared() {
        guard cancellationBarrier.bufferCleared() else { return }
        AppLog.general.info("Buffer cleared — barrier open")
        beginListeningIfPendingIntent()
    }

    private var transcriptSessionPhase: TranscriptSessionPhase {
        switch state {
        case .listening: return .listening
        case .flushing: return .flushing
        default: return .inactive
        }
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

    private func startAudioCapture(_ handler: @escaping @Sendable (Data) -> Void) throws {
        if let startAudio = deps.startAudio {
            try startAudio(handler)
        } else {
            try audio.start(chunkHandler: handler)
        }
    }

    private func stopAudioCapture() {
        if let stopAudio = deps.stopAudio {
            stopAudio()
        } else {
            audio.stop()
        }
    }

    /// Retry a terminal server failure without opening the microphone.
    func retryServer() {
        intent.clearAll()
        cancellationBarrier.reset()
        idleScheduler.cancel()
        transition(to: .starting)
        supervisor.retry()
    }

    private func handleServerState(_ serverState: ServerSupervisor.State) {
        switch serverState {
        case .idle, .stopped:
            idleScheduler.cancel()
            if state == .unloading || state != .idle {
                if state != .unloading {
                    interruptActiveSessionIfNeeded()
                    realtime.disconnect()
                }
                transition(to: .idle)
            }

        case .launching, .waitingForReady:
            if state != .listening && state != .flushing && state != .unloading {
                transition(to: .starting)
            }

        case .restarting(let status):
            idleScheduler.cancel()
            interruptActiveSessionIfNeeded()
            transition(to: .restarting(status))

        case .downloading(let percent):
            if state != .listening && state != .flushing {
                transition(to: .downloading(percent: percent))
            }

        case .running:
            if !realtime.isConnected {
                realtime.connect()
            } else if state != .listening && state != .flushing {
                transition(to: .ready)
                beginListeningIfPendingIntent()
            }

        case .failed(let failure):
            idleScheduler.cancel()
            interruptActiveSessionIfNeeded()
            realtime.disconnect()
            transition(to: .failed(.server(failure)))
        }
    }

    private func interruptActiveSessionIfNeeded() {
        let wasActive = state == .listening || state == .flushing
        guard wasActive else { return }
        intent.interruptActiveSession()
        cancellationBarrier.reset()
        escapeHotKey.unregister()
        stopAudioCapture()
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
            if state == .unloading || didShutdown {
                return
            }
            cancellationBarrier.reset()
            if state == .listening {
                intent.interruptActiveSession()
                escapeHotKey.unregister()
                stopAudioCapture()
                textInserter.discard()
                endIndicatorSession(playSound: true)
                transition(to: .starting)
            } else if state == .ready {
                // Transient idle reconnect does not reset the idle deadline.
                transition(to: .starting)
            } else if state == .flushing {
                intent.clearAll()
                escapeHotKey.unregister()
                textInserter.discard()
                endIndicatorSession(playSound: true)
                transition(to: .starting)
            }
        }
    }

    private func handleDelta(_ delta: String) {
        guard cancellationBarrier.shouldAcceptTranscript(phase: transcriptSessionPhase) else { return }
        sessionTranscript += delta
        print("[transcript delta] \(delta)")
        AppLog.general.info("delta: \(delta, privacy: .public)")
        textInserter.handleDelta(delta)
    }

    private func handleDone(_ transcript: String) {
        guard cancellationBarrier.shouldAcceptTranscript(phase: transcriptSessionPhase) else { return }
        let finalText = transcript.isEmpty ? sessionTranscript : transcript
        print("[transcript done] \(finalText)")
        AppLog.general.info("done: \(finalText, privacy: .public)")
        sessionTranscript = ""

        if state == .flushing {
            let inserted = textInserter.flush()
            if !inserted.isEmpty {
                AppLog.general.info(
                    "buffer flush inserted \(inserted.count, privacy: .public) chars"
                )
            }
            intent.clearAll()
            escapeHotKey.unregister()
            endIndicatorSession(playSound: true)
            if realtime.isConnected, case .running = supervisor.state {
                transition(to: .ready)
                resetIdleSchedulerAfterSession()
            } else {
                transition(to: .starting)
            }
        }
    }

    private func transition(to newState: DictationState) {
        guard state != newState else { return }
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
    private var setupPreferences: SetupPreferences!
    private var onboardingCoordinator: OnboardingCoordinator!
    private var onboardingWindowController: OnboardingWindowController!
    private var remapHealthMonitor: RemapHealthMonitor!
    private var workspaceObservers: [NSObjectProtocol] = []

    private var startStopItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var playSoundsItem: NSMenuItem!
    private var setupChecklistItem: NSMenuItem!
    private var removeRemapItem: NSMenuItem!
    private var micKeyModeItem: NSMenuItem!
    private var holdToTalkModeItem: NSMenuItem!
    private var pressToToggleModeItem: NSMenuItem!
    private var speechProviderItem: NSMenuItem!
    private var voxtralProviderItem: NSMenuItem!
    private var parakeetProviderItem: NSMenuItem!
    private var parakeetModelPathItem: NSMenuItem!
    private var clearParakeetPathItem: NSMenuItem!
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
        id: 1,
        requiresReleaseToRearm: false
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

        setupPreferences = SetupPreferences()
        onboardingCoordinator = OnboardingCoordinator(
            preferences: setupPreferences,
            dependencies: .production(micKeyManager: micKeyManager)
        )
        onboardingWindowController = OnboardingWindowController(coordinator: onboardingCoordinator)
        remapHealthMonitor = RemapHealthMonitor(
            dependencies: RemapHealthMonitor.Dependencies(
                sleep: { try await Task.sleep(for: $0) },
                now: { Date() },
                expectedActive: { [weak self] in self?.setupPreferences.expectedActive ?? false },
                persistenceDesired: { [weak self] in self?.setupPreferences.persistenceDesired ?? true },
                remapStatus: { [weak self] in self?.micKeyManager.remapStatus() ?? .missing },
                launchAgentStatus: { [weak self] in self?.micKeyManager.launchAgentStatus() ?? .absent },
                isMutationInProgress: { [weak self] in self?.onboardingCoordinator.mutationInProgress ?? false },
                isSetupVisibleAndIncomplete: { [weak self] in
                    guard let self else { return false }
                    // Suppress recovery modal whenever the setup window is visible.
                    // Live checklist state is the recovery UI; do not use historical completion.
                    return self.onboardingWindowController.isVisible
                }
            )
        )
        remapHealthMonitor.onIssue = { [weak self] issue in
            self?.presentRemapHealthIssue(issue)
        }

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

        setupChecklistItem = NSMenuItem(
            title: "Setup Checklist…",
            action: #selector(showSetupChecklist),
            keyEquivalent: ""
        )
        setupChecklistItem.target = self
        menu.addItem(setupChecklistItem)

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

        let speechProviderMenu = NSMenu()
        voxtralProviderItem = NSMenuItem(
            title: SpeechProvider.voxtral.displayName,
            action: #selector(selectVoxtralProvider),
            keyEquivalent: ""
        )
        voxtralProviderItem.target = self
        speechProviderMenu.addItem(voxtralProviderItem)

        parakeetProviderItem = NSMenuItem(
            title: SpeechProvider.parakeet.displayName,
            action: #selector(selectParakeetProvider),
            keyEquivalent: ""
        )
        parakeetProviderItem.target = self
        speechProviderMenu.addItem(parakeetProviderItem)

        speechProviderMenu.addItem(.separator())

        parakeetModelPathItem = NSMenuItem(
            title: "Choose Parakeet Model Folder…",
            action: #selector(chooseParakeetModelPath),
            keyEquivalent: ""
        )
        parakeetModelPathItem.target = self
        speechProviderMenu.addItem(parakeetModelPathItem)

        clearParakeetPathItem = NSMenuItem(
            title: "Clear Parakeet Model Path",
            action: #selector(clearParakeetModelPath),
            keyEquivalent: ""
        )
        clearParakeetPathItem.target = self
        speechProviderMenu.addItem(clearParakeetPathItem)

        speechProviderItem = NSMenuItem(title: "Speech Provider", action: nil, keyEquivalent: "")
        speechProviderItem.submenu = speechProviderMenu
        menu.addItem(speechProviderItem)

        menu.addItem(.separator())

        micPermissionItem = NSMenuItem(
            title: "Microphone: …",
            action: #selector(showSetupChecklist),
            keyEquivalent: ""
        )
        micPermissionItem.target = self
        menu.addItem(micPermissionItem)

        axPermissionItem = NSMenuItem(
            title: "Accessibility: …",
            action: #selector(showSetupChecklist),
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
        refreshSpeechProviderItems()
        refreshRemapItems()
        refreshUI(for: .idle)

        registerWorkspaceObservers()
        controller.bootstrap()

        // Auto-show setup on the next run-loop turn until complete.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.setupPreferences.shouldAutoShowSetup {
                OnboardingLog.logger.info("Auto-showing setup checklist (incomplete)")
                self.onboardingWindowController.show()
            }
            if self.setupPreferences.expectedActive {
                self.remapHealthMonitor.scheduleLaunchCheck()
            }
        }
        AppLog.general.info("LocalDictation launched")
    }

    @objc private func toggleDictation() {
        controller.toggleDictation()
    }

    @objc private func showSetupChecklist() {
        onboardingCoordinator.openSetupChecklist()
        onboardingWindowController.show()
        refreshPermissionRows()
        refreshRemapItems()
    }

    @objc private func removeMicKeyRemap() {
        onboardingCoordinator.removeMicKeyRemap()
        if let error = onboardingCoordinator.snapshot.actionError {
            let alert = NSAlert()
            alert.messageText = "Could not remove mic-key remap"
            alert.informativeText = error
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            let alert = NSAlert()
            alert.messageText = "Mic-key remap removed"
            alert.informativeText =
                "The 🎤 key is restored to system behavior. Future restore prompts are suppressed until you install again."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        refreshRemapItems()
        refreshPermissionRows()
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

    @objc private func selectVoxtralProvider() {
        applySpeechProvider(.voxtral)
    }

    @objc private func selectParakeetProvider() {
        applySpeechProvider(.parakeet)
    }

    @objc private func chooseParakeetModelPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Select"
        panel.message =
            "Select a Parakeet CoreML model folder containing Preprocessor/Encoder/Decoder/JointDecisionv3 and parakeet_vocab.json."
        if let current = config.parakeetModelPath, !current.isEmpty {
            let expanded = (current as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        // Accessory-only apps need activation so the open panel is visible.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard ParakeetEngine.containsV3Bundles(at: url) else {
            let alert = NSAlert()
            alert.messageText = "Not a Parakeet v3 model folder"
            alert.informativeText = """
            Expected these items inside the folder:
            • Preprocessor.mlmodelc
            • Encoder.mlmodelc
            • Decoder.mlmodelc
            • JointDecisionv3.mlmodelc
            • parakeet_vocab.json

            Selected: \(url.path)
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        config.parakeetModelPath = url.path
        // Choosing a model folder implies using Parakeet.
        config.provider = .parakeet
        config.save()
        rebootstrapSpeechRuntime()
        refreshSpeechProviderItems()
        AppLog.general.info(
            "Parakeet model path set to \(url.path, privacy: .public); speech runtime restarted"
        )
    }

    @objc private func clearParakeetModelPath() {
        guard config.parakeetModelPath != nil else { return }
        config.parakeetModelPath = nil
        config.save()
        if config.provider == .parakeet {
            rebootstrapSpeechRuntime()
        }
        refreshSpeechProviderItems()
    }

    private func applySpeechProvider(_ provider: SpeechProvider) {
        guard config.provider != provider else {
            refreshSpeechProviderItems()
            return
        }
        config.provider = provider
        config.save()
        rebootstrapSpeechRuntime()
        refreshSpeechProviderItems()
        AppLog.general.info(
            "Speech provider switched to \(provider.rawValue, privacy: .public); speech runtime restarted"
        )
    }

    /// Tear down the active speech runtime and rebuild from the current config
    /// so provider / model-path menu changes apply without quitting the app.
    private func rebootstrapSpeechRuntime() {
        controller.shutdown()
        let fresh = DictationController(config: config)
        fresh.onStateChange = { [weak self] state in
            self?.refreshUI(for: state)
        }
        controller = fresh
        controller.bootstrap()
        refreshUI(for: controller.state)
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
        showSetupChecklist()
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
            case .notRegistered, .notFound:
                // .notFound is not a dead end: on several macOS versions a valid,
                // never-registered app reports .notFound rather than .notRegistered
                // (and it also appears after the system drops an orphaned record).
                // Treat it like .notRegistered and attempt registration; the catch
                // below surfaces the real reason if the system genuinely refuses.
                try service.register()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            @unknown default:
                presentLaunchAtLoginAlert(
                    message: "Launch at Login",
                    informative: "Unexpected login-item status. Open System Settings → General → Login Items and check Local Dictation there."
                )
            }
        } catch {
            let nsError = error as NSError
            AppLog.general.error(
                "Launch at login failed: \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)]"
            )
            presentLaunchAtLoginAlert(
                message: "Launch at Login couldn’t be enabled",
                informative:
                    "The system refused the login-item registration:\n\n\(error.localizedDescription) (\(nsError.domain) \(nsError.code))\n\nIf this persists, the app likely needs a signing identity the system trusts."
            )
        }
        refreshLaunchAtLoginItem()
    }

    func menuWillOpen(_ menu: NSMenu) {
        onboardingCoordinator.refresh()
        refreshLaunchAtLoginItem()
        refreshPermissionRows()
        refreshRemapItems()
        refreshPlaySoundsItem()
        refreshMicKeyModeItems()
        refreshSpeechProviderItems()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        onboardingCoordinator.refresh()
        refreshPermissionRows()
        refreshRemapItems()
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
        teardownOnboardingLifecycle()
        controller.shutdown()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        toggleHotKey.unregister()
        f13HotKey.unregister()
        micKeyInterpreter.reset()
        teardownOnboardingLifecycle()
        controller?.shutdown()
    }

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.remapHealthMonitor.scheduleWakeOrSessionCheck()
            }
        }
        let session = center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.remapHealthMonitor.scheduleWakeOrSessionCheck()
            }
        }
        workspaceObservers = [wake, session]
    }

    private func teardownOnboardingLifecycle() {
        remapHealthMonitor?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    private func presentRemapHealthIssue(_ issue: RemapHealthIssue) {
        let alert = NSAlert()
        switch issue.outcome {
        case .activeButPersistenceNeedsRepair:
            alert.messageText = "Mic-key remap persistence needs repair"
            alert.informativeText =
                "The 🎤 → F13 mapping is active, but login persistence is missing or invalid."
            alert.addButton(withTitle: "Repair Persistence")
        case .expectedMappingMissing:
            alert.messageText = "Mic-key remap missing"
            alert.informativeText =
                "Local Dictation expects the 🎤 → F13 mapping, but it is not active."
            alert.addButton(withTitle: "Restore Now")
        case .healthy, .noExpectation, .probeFailed:
            remapHealthMonitor.notePromptDismissed()
            return
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Setup")
        alert.addButton(withTitle: "Not Now")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let restored = onboardingCoordinator.restoreExpectedRemap()
            refreshRemapItems()
            remapHealthMonitor.notePromptDismissed()
            if !restored {
                // Surface actionable restore/repair failure in the setup checklist.
                showSetupChecklist()
            }
        case .alertSecondButtonReturn:
            remapHealthMonitor.notePromptDismissed()
            showSetupChecklist()
        default:
            remapHealthMonitor.noteNotNow()
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
        case .ready, .idle, .failed, .unloading:
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
        onboardingCoordinator?.refresh()
        let micStatus = onboardingCoordinator?.snapshot.microphone
            ?? SetupMicrophoneStatus.from(AudioCapture.microphoneAuthorizationStatus())
        let micText: String
        switch micStatus {
        case .authorized:
            micText = "Microphone: Granted"
        case .denied:
            micText = "Microphone: Denied"
        case .restricted:
            micText = "Microphone: Restricted"
        case .notRequested:
            micText = "Microphone: Not determined"
        case .unknown:
            micText = "Microphone: Unknown"
        }
        micPermissionItem.title = micText
        micPermissionItem.isEnabled = true
        micPermissionItem.action = #selector(showSetupChecklist)
        micPermissionItem.target = self

        let trusted = onboardingCoordinator?.snapshot.accessibilityTrusted ?? AXIsProcessTrusted()
        if trusted {
            axPermissionItem.title = "Accessibility: Granted"
        } else {
            axPermissionItem.title = "Accessibility: Not granted — open Setup…"
        }
        axPermissionItem.isEnabled = true
        axPermissionItem.action = #selector(showSetupChecklist)
        axPermissionItem.target = self

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
        case .notRegistered, .notFound:
            // .notFound is treated like .notRegistered here to match
            // toggleLaunchAtLogin(), which registers on click in both states.
            launchAtLoginItem.title = "Launch at Login"
            launchAtLoginItem.state = .off
        case .requiresApproval:
            launchAtLoginItem.title = "Launch at Login (approval required…)"
            launchAtLoginItem.state = .mixed
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

    private func refreshSpeechProviderItems() {
        let provider = config.provider
        voxtralProviderItem.state = provider == .voxtral ? .on : .off
        parakeetProviderItem.state = provider == .parakeet ? .on : .off
        speechProviderItem.title = "Speech Provider: \(provider.displayName)"

        if let path = config.parakeetModelPath, !path.isEmpty {
            let display = (path as NSString).abbreviatingWithTildeInPath
            parakeetModelPathItem.title = "Parakeet Model: \(display)"
            clearParakeetPathItem.isEnabled = true
        } else if let resolved = ParakeetEngine.resolveModelDirectory(explicitPath: nil) {
            let display = (resolved.path as NSString).abbreviatingWithTildeInPath
            parakeetModelPathItem.title = "Parakeet Model: \(display) (auto)"
            clearParakeetPathItem.isEnabled = false
        } else {
            parakeetModelPathItem.title = "Choose Parakeet Model Folder…"
            clearParakeetPathItem.isEnabled = false
        }
    }

    private func refreshRemapItems() {
        let status = micKeyManager.remapStatus()
        let agent = micKeyManager.launchAgentStatus()
        let remapped = status == .installed
        let agentPresent: Bool
        switch agent {
        case .loaded, .validButUnloaded, .invalid:
            agentPresent = true
        case .absent:
            agentPresent = false
        }
        removeRemapItem.isEnabled = remapped || agentPresent || setupPreferences?.expectedActive == true
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
    private var edgeLatch: HotKeyEdgeLatch

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

    /// - Parameter requiresReleaseToRearm: F13 hold/toggle needs a paired release. ⌥⌘D and
    ///   Esc re-arm on a later press if release was dropped (Carbon hotkeys do not key-repeat).
    init(
        keyCode: UInt32,
        modifiers: UInt32,
        signature: OSType,
        id: UInt32,
        requiresReleaseToRearm: Bool = true
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.signature = signature
        self.id = id
        self.edgeLatch = HotKeyEdgeLatch(requiresReleaseToRearm: requiresReleaseToRearm)
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
