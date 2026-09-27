import AppKit
import Carbon
import InputMethodKit
import LocalDictationIME
import os

let log = Logger(subsystem: InputMethodIdentity.bundleIdentifier, category: "ime")

/// Timestamped trace to /tmp/ld-ime-debug.log while /tmp/ld-ime-debug.flag
/// exists (diagnostics only; off by default).
func trace(_ message: @autoclosure () -> String) {
    guard FileManager.default.fileExists(atPath: "/tmp/ld-ime-debug.flag") else { return }
    let line = "\(Date().timeIntervalSince1970) \(message())\n"
    let url = URL(fileURLWithPath: "/tmp/ld-ime-debug.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

/// One controller per client text field (created by InputMethodKit). It never
/// consumes keystrokes; it only tells the bridge which field is focused.
@objc(LocalDictationInputController)
final class LocalDictationInputController: IMKInputController {
    // InputMethodKit calls controllers on the main thread.
    /// Keys pass through with the user's own layout (see `overrideLayout`).
    private var overrodeLayout = false

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        overrideLayout(sender)
        nonisolated(unsafe) let (controller, sender) = (self, sender)
        MainActor.assumeIsolated { InputMethodBridge.shared.attach(controller, client: sender) }
    }

    override func deactivateServer(_ sender: Any!) {
        nonisolated(unsafe) let controller = self
        MainActor.assumeIsolated { InputMethodBridge.shared.detach(controller) }
        super.deactivateServer(sender)
    }

    /// The client is ending composition (focus change, click elsewhere): keep
    /// whatever is marked as ordinary text.
    override func commitComposition(_ sender: Any!) {
        nonisolated(unsafe) let (controller, sender) = (self, sender)
        MainActor.assumeIsolated { InputMethodBridge.shared.commitComposition(for: controller, client: sender) }
    }

    /// Chromium and Electron clients only activate an input method that
    /// asks for key events (Squirrel does the same).
    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        if !overrodeLayout { overrideLayout(sender) }
        return false  // typing passes straight through to the app
    }

    /// A keyboard input method has no layout of its own: keys it does not
    /// consume are interpreted with this one — the user's current ASCII
    /// layout (e.g. British), so typing is unchanged while we are selected.
    private func overrideLayout(_ sender: Any?) {
        guard let client = sender as? (any IMKTextInput),
              let layout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(layout, kTISPropertyInputSourceID)
        else { return }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        client.overrideKeyboard(withKeyboardNamed: id)
        overrodeLayout = true
    }
}

/// `MarkedTextClient` over an InputMethodKit client proxy.
final class IMKClientAdapter: MarkedTextClient {
    let client: any IMKTextInput

    init?(_ sender: Any?) {
        guard let client = sender as? (any IMKTextInput) else { return nil }
        self.client = client
    }

    func insertText(_ string: String, replacementRange: NSRange) {
        client.insertText(string, replacementRange: replacementRange)
    }

    func setMarkedText(_ string: String, selectionRange: NSRange, replacementRange: NSRange) {
        let attributed = NSAttributedString(
            string: string,
            attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
        )
        client.setMarkedText(attributed, selectionRange: selectionRange, replacementRange: replacementRange)
    }

    var bundleID: String? { client.bundleIdentifier() }

    /// The character just before the caret/selection, when the client says.
    func precedingCharacter() -> Character?? {
        let selection = client.selectedRange()
        guard selection.location != NSNotFound else { return .none }
        if selection.location == 0 {
            // Start of a field with text, or a client that exposes no text at
            // all (terminals report an empty document): only the former is known.
            let length = client.length()
            return length != NSNotFound && length > 0 ? .some(nil) : .none
        }
        guard let text = client.attributedSubstring(from: NSRange(location: selection.location - 1, length: 1))?.string,
              let last = text.last
        else { return .none }
        return .some(last)
    }

    /// The caret after `offset` characters of marked text, in AppKit screen
    /// coordinates, when the client reports one.
    func caretRect(markedLength offset: Int) -> [Double]? {
        var line = NSRect.zero
        _ = client.attributes(forCharacterIndex: offset, lineHeightRectangle: &line)
        guard line.height > 0, line.origin != .zero else { return nil }
        return [line.origin.x, line.origin.y, max(line.width, 1), line.height]
    }

    /// Full text of the field, when the client exposes it.
    func documentText() -> String? {
        let length = client.length()
        guard length > 0, length != NSNotFound else { return length == 0 ? "" : nil }
        return client.attributedSubstring(from: NSRange(location: 0, length: length))?.string
    }
}

/// Owns the port server, the focused client and the session's composer.
@MainActor
final class InputMethodBridge {
    static let shared = InputMethodBridge()

    private var server: InputMethodPortServer?
    private weak var controller: LocalDictationInputController?
    private var client: IMKClientAdapter?
    private var session: String?
    private var composer = MarkedTextComposer()
    /// Where the previous session ended, for clients whose text is hidden or
    /// unreliable (terminals). Keyed by app: controllers are recreated when
    /// the input source is re-selected.
    private var lastSession: (bundleID: String?, tail: Character?, ended: Date)?

    func start() {
        // The port's run-loop source is on the main run loop.
        let server = InputMethodPortServer { [weak self] request in
            MainActor.assumeIsolated {
                self?.handle(request) ?? InputMethodReply(ok: false, error: "gone", attached: false)
            }
        }
        if !server.start() {
            log.error("port \(InputMethodIdentity.portName, privacy: .public) already in use")
        }
        self.server = server
    }

    func attach(_ controller: LocalDictationInputController, client sender: Any?) {
        self.controller = controller
        client = IMKClientAdapter(sender)
        log.info("attached client \(self.client?.bundleID ?? "?", privacy: .public)")
        trace("attach \(ObjectIdentifier(controller).hashValue) client=\(self.client?.bundleID ?? "?")")
    }

    func detach(_ controller: LocalDictationInputController) {
        trace("detach \(ObjectIdentifier(controller).hashValue) current=\(self.controller === controller)")
        guard self.controller === controller else { return }
        if let client { composer.commitMarked(client: client) }
        self.controller = nil
        client = nil
        log.info("detached client")
    }

    func commitComposition(for controller: LocalDictationInputController, client sender: Any?) {
        guard self.controller === controller, let client = IMKClientAdapter(sender) ?? client else { return }
        composer.commitMarked(client: client)
    }

    private func handle(_ request: InputMethodRequest) -> InputMethodReply {
        let started = Date()
        defer { trace("\(request.op.rawValue) readBack=\(request.readBack) \(Int(Date().timeIntervalSince(started) * 1000))ms") }
        guard let client else {
            return InputMethodReply(ok: false, error: "no focused text field", attached: false)
        }
        switch request.op {
        case .begin:
            session = request.session
            // Continue after existing text with a space, like system dictation.
            var preceding: Character?
            switch request.terminal ? .none : client.precedingCharacter() {
            case .some(let known):
                preceding = known
            case .none:
                if let last = lastSession, last.bundleID == client.bundleID,
                   Date().timeIntervalSince(last.ended) < 30
                {
                    preceding = last.tail
                }
            }
            composer = MarkedTextComposer(precedingCharacter: preceding)
            trace("begin preceding=\(preceding.map { String($0) } ?? "nil")")
        case .probe:
            break
        default:
            guard request.session == session else {
                return reply(ok: false, error: "stale session", client: client, readBack: request.readBack)
            }
            switch request.op {
            case .update:
                composer.update(finalized: request.finalized ?? "", volatile: request.volatile ?? "", client: client)
            case .finish:
                composer.finish(finalText: request.finalized ?? composer.inserted, client: client)
                rememberSession()
            case .cancel:
                composer.commitMarked(client: client)
                rememberSession()
            case .newSegment:
                composer.startNewSegment(client: client)
            case .begin, .probe:
                break
            }
        }
        return reply(ok: true, error: nil, client: client, readBack: request.readBack)
    }

    private func rememberSession() {
        session = nil
        lastSession = (client?.bundleID, composer.lastCharacter, Date())
    }

    private func reply(ok: Bool, error: String?, client: IMKClientAdapter, readBack: Bool) -> InputMethodReply {
        InputMethodReply(
            ok: ok, error: error, attached: true, clientBundleID: client.bundleID,
            marked: composer.marked, documentText: readBack ? client.documentText() : nil,
            caret: client.caretRect(markedLength: (composer.marked as NSString).length)
        )
    }
}
