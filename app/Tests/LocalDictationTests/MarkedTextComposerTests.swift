import Foundation
import LocalDictationIME
import Testing

/// A text field with AppKit's `NSTextInputClient` semantics for marked text:
/// `insertText` / `setMarkedText` with `NSNotFound` replace the marked range
/// (or the selection when nothing is marked).
final class FakeTextField: MarkedTextClient {
    var text: NSMutableString
    var selection: NSRange
    var markedRange = NSRange(location: NSNotFound, length: 0)
    private(set) var calls = 0

    init(_ initial: String = "") {
        text = NSMutableString(string: initial)
        selection = NSRange(location: text.length, length: 0)
    }

    var string: String { text as String }
    var marked: String {
        markedRange.location == NSNotFound ? "" : text.substring(with: markedRange)
    }

    private func target(_ replacement: NSRange) -> NSRange {
        if replacement.location != NSNotFound { return replacement }
        return markedRange.location != NSNotFound ? markedRange : selection
    }

    func insertText(_ string: String, replacementRange: NSRange) {
        calls += 1
        let range = target(replacementRange)
        text.replaceCharacters(in: range, with: string)
        selection = NSRange(location: range.location + (string as NSString).length, length: 0)
        markedRange = NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ string: String, selectionRange: NSRange, replacementRange: NSRange) {
        calls += 1
        let range = target(replacementRange)
        text.replaceCharacters(in: range, with: string)
        let length = (string as NSString).length
        markedRange = length == 0
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: range.location, length: length)
        selection = NSRange(location: range.location + selectionRange.location, length: selectionRange.length)
    }
}

@Suite("MarkedTextComposer")
struct MarkedTextComposerTests {
    @Test("Volatile phrase is marked and can be rewritten wholesale")
    func wholePhraseRevision() {
        let field = FakeTextField("Existing: ")
        var composer = MarkedTextComposer()
        composer.update(finalized: "", volatile: "It is kind of body", client: field)
        #expect(field.string == "Existing: It is kind of body")
        #expect(field.marked == "It is kind of body")
        // A revision that changes the first word and shrinks the phrase.
        composer.update(finalized: "", volatile: "It's kind of buggy", client: field)
        #expect(field.string == "Existing: It's kind of buggy")
        #expect(field.marked == "It's kind of buggy")
    }

    @Test("Finalizing inserts permanently and the next phrase is marked after it")
    func finalizeThenMark() {
        let field = FakeTextField()
        var composer = MarkedTextComposer()
        composer.update(finalized: "", volatile: "So I want to improve this app.", client: field)
        composer.update(finalized: "So I want to improve this app.", volatile: "It is buggy", client: field)
        #expect(field.string == "So I want to improve this app. It is buggy")
        #expect(field.marked == " It is buggy")
        composer.update(finalized: "So I want to improve this app. It is buggy.", volatile: "", client: field)
        #expect(field.string == "So I want to improve this app. It is buggy.")
        #expect(field.marked.isEmpty)
    }

    @Test("Final text replaces the marked tail and leaves nothing marked")
    func finish() {
        let field = FakeTextField("A: ")
        var composer = MarkedTextComposer()
        composer.update(finalized: "one two", volatile: "three for", client: field)
        composer.finish(finalText: "one two three four.", client: field)
        #expect(field.string == "A: one two three four.")
        #expect(field.marked.isEmpty)
    }

    @Test("Text before the caret is never touched, whatever the revisions")
    func existingTextUntouched() {
        let field = FakeTextField("Do not touch this. ")
        var composer = MarkedTextComposer()
        let updates: [(String, String)] = [
            ("", "a"), ("", "a very long phrase that keeps going and going"),
            ("", "x"), ("", ""), ("", "b c"), ("b c", "d"), ("b c d e", ""),
        ]
        for (f, v) in updates {
            composer.update(finalized: f, volatile: v, client: field)
            #expect(field.string.hasPrefix("Do not touch this. "))
        }
        composer.finish(finalText: "b c d e", client: field)
        #expect(field.string == "Do not touch this. b c d e")
    }

    @Test("A revised finalized text is not re-inserted (no duplication)")
    func finalizedRevisionIgnored() {
        let field = FakeTextField()
        var composer = MarkedTextComposer()
        composer.update(finalized: "stops and starts", volatile: "", client: field)
        composer.update(finalized: "stops and stars and then", volatile: "more", client: field)
        #expect(field.string == "stops and starts more")
        composer.update(finalized: "stops and stars and then more words", volatile: "", client: field)
        #expect(field.string == "stops and starts more words")
    }

    @Test("Commit on cancel keeps the shown text")
    func cancelKeepsText() {
        let field = FakeTextField()
        var composer = MarkedTextComposer()
        composer.update(finalized: "keep this", volatile: "and this", client: field)
        composer.commitMarked(client: field)
        #expect(field.string == "keep this and this")
        #expect(field.marked.isEmpty)
    }

    @Test("Emoji and umlauts use UTF-16 ranges correctly")
    func unicode() {
        let field = FakeTextField("👍🏽 ")
        var composer = MarkedTextComposer()
        composer.update(finalized: "", volatile: "Grüße 🎉", client: field)
        composer.update(finalized: "", volatile: "Grüße aus München 🎉🎉", client: field)
        #expect(field.string == "👍🏽 Grüße aus München 🎉🎉")
        composer.finish(finalText: "Grüße aus München.", client: field)
        #expect(field.string == "👍🏽 Grüße aus München.")
    }

    @Test("Voxtral segments: new text follows what is shown")
    func segments() {
        let field = FakeTextField()
        var composer = MarkedTextComposer()
        composer.update(finalized: "Hello there.", volatile: "", client: field)
        composer.startNewSegment(client: field)
        composer.update(finalized: " Again", volatile: "", client: field)
        #expect(field.string == "Hello there. Again")
    }

    @Test("Continuing after existing text adds one separating space")
    func continuesWithSpace() {
        let field = FakeTextField("Earlier sentence.")
        var composer = MarkedTextComposer(precedingCharacter: ".")
        composer.update(finalized: "", volatile: "Next one", client: field)
        #expect(field.string == "Earlier sentence. Next one")
        composer.finish(finalText: "Next one.", client: field)
        #expect(field.string == "Earlier sentence. Next one.")

        let spaced = FakeTextField("Ends with space ")
        var second = MarkedTextComposer(precedingCharacter: " ")
        second.finish(finalText: "no double", client: spaced)
        #expect(spaced.string == "Ends with space no double")
    }

    @Test("Unchanged updates make no client calls")
    func idempotent() {
        let field = FakeTextField()
        var composer = MarkedTextComposer()
        composer.update(finalized: "a", volatile: "b", client: field)
        let calls = field.calls
        composer.update(finalized: "a", volatile: "b", client: field)
        #expect(field.calls == calls)
    }
}
