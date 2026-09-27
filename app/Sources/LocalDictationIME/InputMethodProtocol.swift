import CoreFoundation
import Foundation

/// Wire protocol between the Local Dictation app and its input method.
///
/// The input method (`LocalDictationInput.app`, InputMethodKit) is launched
/// by macOS and attached to whichever text field has focus while it is the
/// selected input source. The app drives it over a local Mach message port:
/// every request carries the full transcript state, so updates are idempotent
/// and a dropped message is healed by the next one.
public enum InputMethodIdentity {
    public static let bundleIdentifier = "com.omcdowell.inputmethod.LocalDictation"
    /// `TISInputSourceID` in the input method's Info.plist.
    public static let inputSourceID = "com.omcdowell.inputmethod.LocalDictation"
    public static let connectionName = "com.omcdowell.inputmethod.LocalDictation_Connection"
    public static let bundleName = "LocalDictationInput.app"
    public static let portName = "com.omcdowell.LocalDictation.InputMethodPort"
}

public struct InputMethodRequest: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable {
        /// Start a session in the focused field (resets the composer).
        case begin
        /// Show `finalized` permanently and `volatile` as marked text.
        case update
        /// `finalized` is the final text; nothing stays marked.
        case finish
        /// Keep what is shown (commit marked text) and end the session.
        case cancel
        /// Voxtral end-of-speech: keep what is shown, restart finalized text.
        case newSegment
        /// Report status (and the field's text when `readBack`).
        case probe
    }

    public var op: Op
    public var session: String
    public var finalized: String?
    public var volatile: String?
    /// Ask for the focused field's full text in the reply (tests/diagnostics).
    public var readBack: Bool
    /// `begin` only: the target is a terminal, whose reported text around the
    /// cursor does not reflect the shell line.
    public var terminal: Bool

    public init(op: Op, session: String, finalized: String? = nil, volatile: String? = nil,
                readBack: Bool = false, terminal: Bool = false) {
        self.op = op
        self.session = session
        self.finalized = finalized
        self.volatile = volatile
        self.readBack = readBack
        self.terminal = terminal
    }
}

public struct InputMethodReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    /// A text field is attached to the input method right now.
    public var attached: Bool
    public var clientBundleID: String?
    public var marked: String?
    public var documentText: String?

    public init(ok: Bool, error: String? = nil, attached: Bool, clientBundleID: String? = nil,
                marked: String? = nil, documentText: String? = nil) {
        self.ok = ok
        self.error = error
        self.attached = attached
        self.clientBundleID = clientBundleID
        self.marked = marked
        self.documentText = documentText
    }
}

/// Client side of the port (the app). Synchronous request/reply.
public enum InputMethodPortClient {
    public static func send(_ request: InputMethodRequest, timeout: TimeInterval = 0.5) -> InputMethodReply? {
        guard let remote = CFMessagePortCreateRemote(nil, InputMethodIdentity.portName as CFString),
              let body = try? JSONEncoder().encode(request)
        else { return nil }
        defer { CFMessagePortInvalidate(remote) }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            remote, 1, body as CFData, timeout, timeout, CFRunLoopMode.defaultMode.rawValue, &reply
        )
        guard status == kCFMessagePortSuccess, let data = reply?.takeRetainedValue() as Data? else { return nil }
        return try? JSONDecoder().decode(InputMethodReply.self, from: data)
    }
}

/// Server side of the port (the input method), on the main run loop.
public final class InputMethodPortServer {
    public typealias Handler = (InputMethodRequest) -> InputMethodReply

    private let handler: Handler
    private var port: CFMessagePort?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Returns false when another process already owns the port name.
    @discardableResult
    public func start() -> Bool {
        var context = CFMessagePortContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: CFMessagePortCallBack = { _, _, data, info in
            guard let info, let data else { return nil }
            let server = Unmanaged<InputMethodPortServer>.fromOpaque(info).takeUnretainedValue()
            let reply: InputMethodReply
            if let request = try? JSONDecoder().decode(InputMethodRequest.self, from: data as Data) {
                reply = server.handler(request)
            } else {
                reply = InputMethodReply(ok: false, error: "malformed request", attached: false)
            }
            guard let body = try? JSONEncoder().encode(reply) else { return nil }
            return Unmanaged.passRetained(body as CFData)
        }
        var shouldFree: DarwinBoolean = false
        guard let port = CFMessagePortCreateLocal(
            nil, InputMethodIdentity.portName as CFString, callback, &context, &shouldFree
        ) else { return false }
        self.port = port
        let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }
}
