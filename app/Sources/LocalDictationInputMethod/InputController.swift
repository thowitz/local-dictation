import AppKit
import InputMethodKit
import LocalDictationIME
import os

let log = Logger(subsystem: InputMethodIdentity.bundleIdentifier, category: "ime")

/// One controller per client text field (created by InputMethodKit). It never
/// consumes keystrokes; it only tells the bridge which field is focused.
@objc(LocalDictationInputController)
final class LocalDictationInputController: IMKInputController {
    // InputMethodKit calls controllers on the main thread.
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
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

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        false  // typing passes straight through to the app
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
    }

    func detach(_ controller: LocalDictationInputController) {
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
        guard let client else {
            return InputMethodReply(ok: false, error: "no focused text field", attached: false)
        }
        switch request.op {
        case .begin:
            session = request.session
            composer = MarkedTextComposer()
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
                session = nil
            case .cancel:
                composer.commitMarked(client: client)
                session = nil
            case .newSegment:
                composer.startNewSegment(client: client)
            case .begin, .probe:
                break
            }
        }
        return reply(ok: true, error: nil, client: client, readBack: request.readBack)
    }

    private func reply(ok: Bool, error: String?, client: IMKClientAdapter, readBack: Bool) -> InputMethodReply {
        InputMethodReply(
            ok: ok, error: error, attached: true, clientBundleID: client.bundleID,
            marked: composer.marked, documentText: readBack ? client.documentText() : nil
        )
    }
}
