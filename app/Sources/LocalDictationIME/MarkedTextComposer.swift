import Foundation

/// The subset of the macOS text input client API (`NSTextInputClient` /
/// `IMKTextInput`) the composer drives. Ranges are UTF-16 based, as in AppKit.
public protocol MarkedTextClient: AnyObject {
    /// Insert committed text. With `replacementRange.location == NSNotFound`
    /// the client replaces its marked text (or, if none, the selection).
    func insertText(_ string: String, replacementRange: NSRange)
    /// Replace the marked text (or the selection, if none) with `string` and
    /// keep it marked. An empty string removes the marked text.
    func setMarkedText(_ string: String, selectionRange: NSRange, replacementRange: NSRange)
}

/// Turns streaming transcript updates into text-input calls, the way system
/// dictation does: text that may still change is *marked* (underlined,
/// provisional) and replaced wholesale on every update; finalized text is
/// inserted permanently. Nothing is ever backspaced, so a revision of any
/// length — a whole phrase — is safe, and nothing already committed can be
/// duplicated or overwritten.
public struct MarkedTextComposer: Sendable {
    /// Finalized text of the current segment already inserted.
    public private(set) var inserted = ""
    /// Text currently shown as marked.
    public private(set) var marked = ""
    /// Last character this session committed (nil before the first word).
    private var screenTail: Character?

    public init() {}

    /// Apply one update. `finalized` must extend what was already finalized
    /// (append-only); `volatile` is the full provisional tail after it.
    public mutating func update(finalized: String, volatile: String, client: some MarkedTextClient) {
        var delta = ""
        if finalized.hasPrefix(inserted) {
            delta = String(finalized.dropFirst(inserted.count))
        }
        // Either way the segment's finalized text is now `finalized`: a
        // revision of already-inserted text is ignored, never re-typed.
        inserted = finalized

        let insertText = Self.join(delta, after: screenTail)
        let tailAfterInsert = insertText.last ?? screenTail
        let nextMarked = Self.join(volatile, after: tailAfterInsert)

        if !insertText.isEmpty {
            // Replaces the current marked text with the finalized words.
            client.insertText(insertText, replacementRange: Self.notFound)
            screenTail = tailAfterInsert
            marked = ""
        }
        if nextMarked != marked {
            client.setMarkedText(
                nextMarked,
                selectionRange: NSRange(location: nextMarked.utf16.count, length: 0),
                replacementRange: Self.notFound
            )
            marked = nextMarked
        }
    }

    /// Final text for the segment: everything becomes permanent.
    public mutating func finish(finalText: String, client: some MarkedTextClient) {
        update(finalized: finalText, volatile: "", client: client)
    }

    /// Keep whatever is shown (Esc cancel, focus loss): commit the marked text.
    public mutating func commitMarked(client: some MarkedTextClient) {
        guard !marked.isEmpty else { return }
        client.insertText(marked, replacementRange: Self.notFound)
        screenTail = marked.last
        marked = ""
    }

    /// Append-only runtimes (Voxtral) restart their text after end-of-speech;
    /// what is on screen stays, and the next text follows it.
    public mutating func startNewSegment(client: some MarkedTextClient) {
        commitMarked(client: client)
        inserted = ""
    }

    /// `text` as it should follow `tail`: exactly one separating space
    /// between words, none at the start of the session.
    static func join(_ text: String, after tail: Character?) -> String {
        guard let first = text.first else { return text }
        guard let tail else { return String(text.drop(while: { $0 == " " })) }
        if tail.isWhitespace || first.isWhitespace || first.isPunctuation {
            return text
        }
        return " " + text
    }

    static let notFound = NSRange(location: NSNotFound, length: 0)
}
