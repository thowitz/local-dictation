import AppKit
import Carbon
import Foundation
import LocalDictationIME
import os

/// Inserts dictation through the Local Dictation input method, the way system
/// dictation does: provisional text is marked (underlined) and replaced in
/// place, finalized text is committed. No synthetic keystrokes, so revisions
/// of any length are safe and nothing can be duplicated or overwritten.
///
/// Per session, by `InsertionMethod`:
/// - `.switchPerDictation`: select the input method, restore the user's
///   source afterwards (hiding the caret badge around both switches).
/// - `.alwaysSelected`: the input method stays selected; nothing switches
///   (it is re-selected if the user moved away).
///
/// Then wait for it to attach to the focused field and stream updates. If it
/// never attaches, `onUnavailable` fires and the caller falls back to keystrokes.
@MainActor
final class InputMethodInserter {
    enum Status: Equatable {
        case idle
        case attaching
        case attached
        case failed(String)
    }

    let method: InsertionMethod
    let installer = InputMethodInstaller()
    private(set) var status: Status = .idle
    /// The input method attached this session (text may be on screen).
    private(set) var didAttach = false
    /// Ask the input method to return the field's text with every reply
    /// (verification harness / diagnostics).
    var readBack = false
    /// Latest reply from the input method.
    private(set) var lastReply: InputMethodReply?
    /// Called once per session if the input method cannot be used.
    var onUnavailable: ((String) -> Void)?

    private let badge: InputSourceBadge?
    private var previousSource: TISInputSource?
    /// The previous session's delayed end (restore the keyboard source);
    /// cancelled if a new session starts first.
    private var pendingEnd: (task: Task<Void, Never>, action: @MainActor () -> Void, restores: TISInputSource?)?
    private var session = ""
    private var pending: InputMethodRequest?
    private var attachTask: Task<Void, Never>?
    private var selectedSource: TISInputSource?
    /// The focused app is a terminal (see `InputMethodRequest.terminal`).
    private var terminal = false
    private let attachTimeout: Duration

    init(method: InsertionMethod, hideBadge: Bool = true, attachTimeout: Duration = .seconds(1.5)) {
        precondition(method.usesInputMethod, "keystrokes need no input method")
        self.method = method
        badge = hideBadge ? .shared : nil
        self.attachTimeout = attachTimeout
    }

    /// Start using the input method for this session. Returns false when it
    /// is not installed or cannot be selected (use keystrokes instead).
    func begin(terminal: Bool = false) -> Bool {
        end(restoreDelay: .zero)
        self.terminal = terminal
        guard let source = installer.enabledSource() else {
            status = .failed("input method not enabled")
            return false
        }
        switch method {
        case .switchPerDictation:
            previousSource = Self.sourceToRestore(pending: pendingEnd?.restores)
            pendingEnd?.task.cancel()
            pendingEnd = nil
            guard select(source) else { return false }
        case .alwaysSelected:
            pendingEnd?.task.cancel()
            pendingEnd = nil
            guard select(source) else { return false }
        case .keystrokes:
            return false
        }
        session = UUID().uuidString
        status = .attaching
        didAttach = false
        pending = nil
        selectedSource = source
        attachTask = Task { [weak self] in await self?.waitForAttach() }
        return true
    }

    func update(finalized: String, volatile: String) {
        send(InputMethodRequest(op: .update, session: session, finalized: finalized, volatile: volatile))
    }

    func newSegment() {
        send(InputMethodRequest(op: .newSegment, session: session))
    }

    /// Deliver the final text; returns false if it could not be delivered.
    @discardableResult
    func finish(finalText: String) -> Bool {
        let delivered = send(InputMethodRequest(op: .finish, session: session, finalized: finalText))
        end(restoreDelay: .milliseconds(150))
        return delivered
    }

    /// Keep what is shown and end the session.
    func cancel() {
        send(InputMethodRequest(op: .cancel, session: session))
        end(restoreDelay: .milliseconds(150))
    }

    /// Where the caret is in the attached field (AppKit screen coordinates).
    func caretRect() -> CGRect? {
        guard status == .attached,
              let reply = InputMethodPortClient.send(
                  InputMethodRequest(op: .probe, session: session), timeout: 0.1
              ),
              reply.attached, let c = reply.caret, c.count == 4
        else { return nil }
        return CGRect(x: c[0], y: c[1], width: c[2], height: c[3])
    }

    /// Stop the session: restore the user's keyboard source after a
    /// per-dictation switch.
    func end(restoreDelay: Duration) {
        attachTask?.cancel()
        attachTask = nil
        pending = nil
        if status != .idle {
            status = .idle
        }
        let action: @MainActor () -> Void
        var restores: TISInputSource?
        if let previous = previousSource {
            let badge = badge
            action = {
                badge?.suppress()
                TISSelectInputSource(previous)
                badge?.restore(after: InputSourceBadge.settleTime)
            }
            restores = previous
        } else {
            badge?.restore(after: InputSourceBadge.settleTime)
            selectedSource = nil
            return
        }
        selectedSource = nil
        previousSource = nil
        if restoreDelay == .zero {
            action()
        } else {
            // Let the client process the last insert before the IME detaches.
            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(for: restoreDelay)
                guard !Task.isCancelled else { return }
                action()
                self?.pendingEnd = nil
            }
            pendingEnd = (task, action, restores)
        }
    }

    /// Apply a pending delayed end right away (app quitting).
    func restoreNow() {
        if let pending = pendingEnd {
            pending.task.cancel()
            pendingEnd = nil
            pending.action()
        }
        badge?.restoreNow()
    }

    /// Leave the method (menu change): put the user's layout back if we kept
    /// the keyboard input method selected.
    func deactivate() {
        restoreNow()
        guard method == .alwaysSelected,
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              InputMethodInstaller.sourceID(current) == InputMethodIdentity.inputSourceID,
              let layout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        else { return }
        badge?.suppress()
        TISSelectInputSource(layout)
        badge?.restore(after: InputSourceBadge.settleTime)
    }

    /// Enter the method (launch / menu change): keep the keyboard input
    /// method selected from now on.
    func activate() {
        guard method == .alwaysSelected, let source = installer.enabledSource() else { return }
        _ = select(source)
        badge?.restore(after: InputSourceBadge.settleTime)
    }

    /// What to switch back to after the session: the user's current source,
    /// or — if ours is already selected (a restore still pending, or left
    /// over from a crash) — the pending target or their ASCII keyboard layout.
    private static func sourceToRestore(pending: TISInputSource?) -> TISInputSource? {
        if let pending { return pending }
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           InputMethodInstaller.sourceID(current) != InputMethodIdentity.inputSourceID
        {
            return current
        }
        return TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
    }

    // MARK: - Internals

    /// Select the keyboard input method unless it already is. macOS draws a
    /// generic glyph as our badge whatever icon or label the bundle declares
    /// (tested on macOS 27), so it is hidden too; the caret mic is our own.
    private func select(_ source: TISInputSource) -> Bool {
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           InputMethodInstaller.sourceID(current) == InputMethodIdentity.inputSourceID
        {
            return true
        }
        badge?.suppress()
        guard TISSelectInputSource(source) == noErr else {
            badge?.restoreNow()
            status = .failed("could not select input method")
            return false
        }
        return true
    }

    @discardableResult
    private func send(_ request: InputMethodRequest) -> Bool {
        var request = request
        request.readBack = readBack
        switch status {
        case .attached:
            let reply = InputMethodPortClient.send(request)
            lastReply = reply ?? lastReply
            guard let reply, reply.ok else {
                AppLog.insertion.error("input method request \(request.op.rawValue, privacy: .public) failed")
                return false
            }
            return true
        case .attaching:
            // Every request carries full state: keep only the newest.
            if request.op == .update || pending == nil || request.op == .finish {
                pending = request
            }
            if request.op == .finish || request.op == .cancel {
                return flushIfAttached(waitingUpTo: .milliseconds(800))
            }
            return false
        case .idle, .failed:
            return false
        }
    }

    private func waitForAttach() async {
        let clock = ContinuousClock()
        let deadline = clock.now + attachTimeout
        // Clients apply source changes asynchronously: an end from the previous
        // session can land after our selection and leave the input method
        // detached. Re-select once, late enough not to fight a normal attach.
        var reselectAt: ContinuousClock.Instant? = clock.now + .milliseconds(700)
        while !Task.isCancelled, clock.now < deadline {
            if tryBegin() { return }
            if let at = reselectAt, clock.now >= at {
                reselect()
                reselectAt = nil
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard !Task.isCancelled, status == .attaching else { return }
        fail("input method did not attach to the focused field")
    }

    private func reselect() {
        guard let ours = selectedSource else { return }
        AppLog.insertion.info("input method not attached yet; re-selecting")
        guard let away = previousSource ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        else { return }
        badge?.suppress()
        TISSelectInputSource(away)
        TISSelectInputSource(ours)
        if method == .alwaysSelected {
            badge?.restore(after: InputSourceBadge.settleTime)
        }
    }

    /// Synchronous variant used when the session ends while still attaching.
    private func flushIfAttached(waitingUpTo limit: Duration) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if tryBegin() { return true }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return false
    }

    private func tryBegin() -> Bool {
        guard let reply = InputMethodPortClient.send(
            InputMethodRequest(op: .begin, session: session, terminal: terminal), timeout: 0.2
        ), reply.ok, reply.attached else { return false }
        status = .attached
        didAttach = true
        lastReply = reply
        AppLog.insertion.info(
            "input method attached to \(reply.clientBundleID ?? "?", privacy: .public)"
        )
        if let pending {
            self.pending = nil
            send(pending)
        }
        return true
    }

    private func fail(_ reason: String) {
        AppLog.insertion.error("\(reason, privacy: .public) — falling back to keystrokes")
        status = .failed(reason)
        end(restoreDelay: .zero)
        status = .failed(reason)
        onUnavailable?(reason)
    }
}

/// macOS's input-source badge beside the caret (Sonoma+), which appears on
/// every source change: "A" for a keyboard layout, the input method's icon
/// for ours. `TSMLanguageIndicatorEnabled` = false turns it off for all apps
/// and running apps honour the change at once, so it is turned off just for
/// the switches and restored once they have settled.
@MainActor
final class InputSourceBadge {
    static let shared = InputSourceBadge()
    /// How long after a switch the badge stays off (the client shows it
    /// asynchronously once it processes the change).
    static let settleTime: Duration = .seconds(3)

    private static let key = "TSMLanguageIndicatorEnabled" as CFString
    /// Set while we have the badge off, so a crash can be undone at launch.
    private static let markerKey = "inputSourceBadgeSuppressed"
    private var suppressed = false
    private var restoreTask: Task<Void, Never>?

    func suppress() {
        restoreTask?.cancel()
        restoreTask = nil
        guard !suppressed else { return }
        // The user turned the badge off themselves: leave their setting alone.
        if Self.userValue() == false { return }
        Self.write(false)
        suppressed = true
        AppIdentity.defaults.set(true, forKey: Self.markerKey)
    }

    func restore(after delay: Duration) {
        guard suppressed else { return }
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.restoreNow()
        }
    }

    func restoreNow() {
        restoreTask?.cancel()
        restoreTask = nil
        guard suppressed else { return }
        Self.write(nil)
        suppressed = false
        AppIdentity.defaults.removeObject(forKey: Self.markerKey)
    }

    /// Undo a suppression left behind by a crash or force-quit.
    static func recoverAfterCrash() {
        guard AppIdentity.defaults.bool(forKey: markerKey) else { return }
        write(nil)
        AppIdentity.defaults.removeObject(forKey: markerKey)
    }

    private static func userValue() -> Bool? {
        CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? Bool
    }

    /// nil removes the key (macOS default: badge on).
    private static func write(_ value: Bool?) {
        CFPreferencesSetValue(
            key, value.map { $0 as CFBoolean }, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

/// Installs the bundled input method into `~/Library/Input Methods` and
/// registers it with the Text Input Sources service.
struct InputMethodInstaller: Sendable {
    enum EnableResult: Equatable {
        case enabled
        /// Newly enabled: processes started earlier (this one included) keep
        /// seeing the source as disabled.
        case enabledNow
        /// The user adds it in Keyboard → Input Sources (writing the
        /// enabled-sources list ourselves needs Full Disk Access).
        case needsUser
        case notInstalled
    }

    var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods", isDirectory: true)
            .appendingPathComponent(InputMethodIdentity.bundleName, isDirectory: true)
    }

    /// The copy shipped inside the app (or `LOCAL_DICTATION_IME_DIR` in development).
    var embeddedURL: URL? {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["LOCAL_DICTATION_IME_DIR"] {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        }
        let url = base.appendingPathComponent(InputMethodIdentity.bundleName, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func sourceID(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// Diagnostics: treat a registered-but-disabled source as usable.
    nonisolated(unsafe) static var allowDisabledForTesting = false
    /// `enable()` turned it on in this process (whose TIS view stays stale).
    nonisolated(unsafe) private static var enabledThisRun = false

    /// Our source if registered (enabled or not).
    func inputSource() -> TISInputSource? {
        source(includeDisabled: true)
    }

    /// Our source only if it is enabled.
    func enabledSource() -> TISInputSource? {
        source(includeDisabled: Self.allowDisabledForTesting || Self.enabledThisRun)
    }

    private func source(includeDisabled: Bool) -> TISInputSource? {
        // List everything installed and read the enabled property.
        let filter = [kTISPropertyInputSourceID as String: InputMethodIdentity.inputSourceID] as CFDictionary
        guard let source = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
        else { return nil }
        if includeDisabled { return source }
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else { return nil }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()) ? source : nil
    }

    /// Registered and enabled.
    func isEnabled() -> Bool {
        enabledSource() != nil
    }

    /// Install, register and try to enable, then start the input method.
    @MainActor
    @discardableResult
    func setUp() -> EnableResult {
        installAndRegister()
        let result = enable()
        prelaunch(restart: result == .enabledNow)
        return result
    }

    /// Enable the source the way macOS records it. `TISEnableInputSource`
    /// returns noErr for a third-party input method without enabling it, so
    /// write the enabled-sources entries directly. `com.apple.inputsources`
    /// is only writable with Full Disk Access; without it the user adds the
    /// input method in Keyboard → Input Sources once.
    @discardableResult
    func enable() -> EnableResult {
        guard inputSource() != nil else { return .notInstalled }
        if isEnabled() { return .enabled }
        let entry = [
            "Bundle ID": InputMethodIdentity.bundleIdentifier,
            "InputSourceKind": "Keyboard Input Method",
        ]
        let lists = [
            ("com.apple.inputsources", "AppleEnabledThirdPartyInputSources"),
            ("com.apple.HIToolbox", "AppleEnabledInputSources"),
        ]
        for (domain, key) in lists {
            var list = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? [[String: Any]] ?? []
            list.removeAll { $0["Bundle ID"] as? String == InputMethodIdentity.bundleIdentifier }
            list.append(entry)
            CFPreferencesSetAppValue(key as CFString, list as CFArray, domain as CFString)
            guard CFPreferencesAppSynchronize(domain as CFString) else {
                AppLog.insertion.info("could not write \(domain, privacy: .public) (needs Full Disk Access)")
                return .needsUser
            }
        }
        Self.enabledThisRun = true
        AppLog.insertion.info("enabled input method \(InputMethodIdentity.bundleIdentifier, privacy: .public)")
        return .enabledNow
    }

    /// Start the input method's process (a no-op if it is running).
    func launch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: installedURL, configuration: configuration) { _, error in
            if let error {
                AppLog.insertion.error("input method launch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Copy the embedded bundle if it is missing or different, then register.
    @discardableResult
    func installAndRegister() -> TISInputSource? {
        let fm = FileManager.default
        let target = installedURL
        if let embedded = embeddedURL, !Self.bundlesMatch(embedded, target) {
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: embedded, to: target)
                // A running old copy keeps serving until it exits.
                terminateRunning()
                AppLog.insertion.info("installed input method at \(target.path, privacy: .public)")
            } catch {
                AppLog.insertion.error("input method install failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guard fm.fileExists(atPath: target.path) else { return nil }
        let status = TISRegisterInputSource(target as CFURL)
        if status != noErr {
            AppLog.insertion.error("TISRegisterInputSource failed: \(status, privacy: .public)")
        }
        return inputSource()
    }

    static func bundlesMatch(_ a: URL, _ b: URL) -> Bool {
        let files = ["Contents/MacOS/LocalDictationInput", "Contents/Info.plist"]
        return files.allSatisfy { file in
            guard let da = FileManager.default.contents(atPath: a.appendingPathComponent(file).path),
                  let db = FileManager.default.contents(atPath: b.appendingPathComponent(file).path)
            else { return false }
            return da == db
        }
    }

    /// Start the input method's process ahead of the first dictation, without
    /// selecting anything (no badge). The first launch after an install or
    /// update takes seconds (the system assesses the new binary) — longer than
    /// a dictation should wait before falling back to keystrokes. `restart`
    /// replaces a running copy whose view of the enabled sources is stale.
    @MainActor
    func prelaunch(restart: Bool = false) {
        guard isEnabled() else { return }
        let running = { NSRunningApplication.runningApplications(withBundleIdentifier: InputMethodIdentity.bundleIdentifier) }
        guard restart || running().isEmpty else { return }
        Task { @MainActor in
            if restart {
                terminateRunning()
                for _ in 0..<40 where !running().isEmpty {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            launch()
        }
    }

    private func terminateRunning() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: InputMethodIdentity.bundleIdentifier) {
            app.terminate()
        }
    }
}
