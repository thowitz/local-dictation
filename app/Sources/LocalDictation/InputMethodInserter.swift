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
/// Per session: select the input method (remembering the user's source),
/// wait for it to attach to the focused field, stream updates, then restore
/// the previous source. If it never attaches, `onUnavailable` fires and the
/// caller falls back to keystroke typing.
@MainActor
final class InputMethodInserter {
    enum Status: Equatable {
        case idle
        case attaching
        case attached
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// The input method attached this session (text may be on screen).
    private(set) var didAttach = false
    /// Called once per session if the input method cannot be used.
    var onUnavailable: ((String) -> Void)?

    private var previousSource: TISInputSource?
    private var session = ""
    private var pending: InputMethodRequest?
    private var attachTask: Task<Void, Never>?
    private let attachTimeout: Duration

    init(attachTimeout: Duration = .seconds(1.5)) {
        self.attachTimeout = attachTimeout
    }

    /// Switch to the input method for this session. Returns false when it is
    /// not installed or cannot be selected (use keystrokes instead).
    func begin() -> Bool {
        end(restoreDelay: .zero)
        // Only an input source the user already approved: enabling one
        // triggers macOS's approval UI, which belongs in the Setup Checklist.
        guard let source = InputMethodInstaller.enabledSource() else {
            status = .failed("input method not enabled")
            return false
        }
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        if let current, InputMethodInstaller.sourceID(current) != InputMethodIdentity.inputSourceID {
            previousSource = current
        }
        guard TISSelectInputSource(source) == noErr else {
            status = .failed("could not select input method")
            return false
        }
        session = UUID().uuidString
        status = .attaching
        didAttach = false
        pending = nil
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

    /// Stop the session and put the user's input source back.
    func end(restoreDelay: Duration) {
        attachTask?.cancel()
        attachTask = nil
        pending = nil
        if status != .idle {
            status = .idle
        }
        guard let previous = previousSource else { return }
        previousSource = nil
        if restoreDelay == .zero {
            TISSelectInputSource(previous)
        } else {
            // Let the client process the last insert before the IME detaches.
            Task { @MainActor in
                try? await Task.sleep(for: restoreDelay)
                TISSelectInputSource(previous)
            }
        }
    }

    // MARK: - Internals

    @discardableResult
    private func send(_ request: InputMethodRequest) -> Bool {
        switch status {
        case .attached:
            guard let reply = InputMethodPortClient.send(request), reply.ok else {
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
        while !Task.isCancelled, clock.now < deadline {
            if tryBegin() { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard !Task.isCancelled, status == .attaching else { return }
        fail("input method did not attach to the focused field")
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
            InputMethodRequest(op: .begin, session: session), timeout: 0.2
        ), reply.ok, reply.attached else { return false }
        status = .attached
        didAttach = true
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

/// Installs the bundled input method into `~/Library/Input Methods` and
/// registers it with the Text Input Sources service.
enum InputMethodInstaller {
    static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods", isDirectory: true)
            .appendingPathComponent(InputMethodIdentity.bundleName, isDirectory: true)
    }

    /// The copy shipped inside the app (or `LOCAL_DICTATION_IME_BUNDLE` in development).
    static var embeddedURL: URL? {
        if let override = ProcessInfo.processInfo.environment["LOCAL_DICTATION_IME_BUNDLE"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(InputMethodIdentity.bundleName, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func sourceID(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// Our source if registered (enabled or not).
    static func inputSource() -> TISInputSource? {
        source(includeDisabled: true)
    }

    /// Our source only if the user has enabled it.
    static func enabledSource() -> TISInputSource? {
        source(includeDisabled: false)
    }

    private static func source(includeDisabled: Bool) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: InputMethodIdentity.inputSourceID] as CFDictionary
        let list = TISCreateInputSourceList(filter, includeDisabled)?.takeRetainedValue() as? [TISInputSource]
        return list?.first
    }

    /// Registered and enabled (the user approved it in System Settings).
    static func isEnabled() -> Bool {
        enabledSource() != nil
    }

    /// Install + register, then ask macOS to enable it (it shows its own
    /// approval UI for third-party input sources).
    static func requestEnable() {
        guard let source = installAndRegister() else { return }
        TISEnableInputSource(source)
    }

    /// Copy the embedded bundle if it is missing or different, then register.
    @discardableResult
    static func installAndRegister() -> TISInputSource? {
        let fm = FileManager.default
        let target = installedURL
        if let embedded = embeddedURL, !bundlesMatch(embedded, target) {
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: embedded, to: target)
                // A running old copy keeps serving until it exits.
                terminateRunningInputMethod()
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
        let exe = "Contents/MacOS/LocalDictationInput"
        guard let da = FileManager.default.contents(atPath: a.appendingPathComponent(exe).path),
              let db = FileManager.default.contents(atPath: b.appendingPathComponent(exe).path)
        else { return false }
        return da == db
    }

    private static func terminateRunningInputMethod() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: InputMethodIdentity.bundleIdentifier) {
            app.terminate()
        }
    }
}
