import Testing
@testable import LocalDictation

/// Applies edits the way a text field would, so tests can assert what the
/// user actually sees.
struct ScreenModel {
    var text: String

    init(_ text: String = "") {
        self.text = text
    }

    mutating func apply(_ edit: TypingEdit) {
        text.removeLast(min(edit.deleteCount, text.count))
        text += edit.insert
    }
}

@Suite("DictationTypist")
struct DictationTypistTests {
    @Test("Draft is corrected in place; committed text only grows")
    func draftCorrectedCommittedGrows() {
        var typist = DictationTypist()
        var screen = ScreenModel("Existing prompt: ")

        screen.apply(typist.apply(committed: "", draft: "hello wor"))
        #expect(screen.text == "Existing prompt: hello wor")

        let edit = typist.apply(committed: "hello", draft: "world how")
        #expect(edit == TypingEdit(deleteCount: 0, insert: "ld how"))
        screen.apply(edit)

        // Draft revision only touches the draft tail.
        let revise = typist.apply(committed: "hello world", draft: "who are")
        #expect(revise.deleteCount == 3)
        screen.apply(revise)
        #expect(screen.text == "Existing prompt: hello world who are")

        screen.apply(typist.finish(finalText: "hello world, how are you?"))
        #expect(screen.text == "Existing prompt: hello world, how are you?")
    }

    @Test("Locked committed text is never deleted, even if a runtime revises it")
    func lockedTextNeverDeleted() {
        var typist = DictationTypist()
        var screen = ScreenModel("keep me ")
        screen.apply(typist.apply(committed: "stops and starts", draft: ""))
        // Protocol violation: committed text rewritten.
        let edit = typist.apply(committed: "stops andff and then", draft: "more")
        #expect(edit.deleteCount == 0)
        screen.apply(edit)
        #expect(screen.text == "keep me stops and starts then more")
        #expect(typist.realignCount == 1)
    }

    @Test("Deep revision holds, then resumes after the stale draft without repeating it")
    func deepRevisionHoldsThenAligns() {
        var typist = DictationTypist(maxRevision: 10)
        var screen = ScreenModel("PROMPT ")
        screen.apply(typist.apply(committed: "one", draft: "two three four five six"))

        // Revision from the first draft word: 22 backspaces > cap → hold.
        let held = typist.apply(committed: "one to three four", draft: "five six")
        #expect(held.isEmpty)

        // Committed catches up past the stale draft: resume after "six".
        screen.apply(typist.apply(committed: "one to three four five six seven", draft: "eight"))
        #expect(screen.text == "PROMPT one two three four five six seven eight")

        screen.apply(typist.finish(finalText: "one to three four five six seven eight."))
        #expect(screen.text == "PROMPT one two three four five six seven eight.")
        #expect(typist.realignCount == 1)
    }

    @Test("A hold that never aligns resumes at release rather than losing words")
    func unalignedHoldResumesAtRelease() {
        var typist = DictationTypist(maxRevision: 5)
        var screen = ScreenModel()
        screen.apply(typist.apply(committed: "alpha", draft: "bravo charlie"))
        #expect(typist.apply(committed: "alpha", draft: "delta echo").isEmpty)
        screen.apply(typist.finish(finalText: "alpha delta echo"))
        #expect(screen.text.hasPrefix("alpha bravo charlie"))
        #expect(screen.text.hasSuffix("delta echo"))
    }

    @Test("Long session: every edit stays in the draft tail; release does not rewrite")
    func longSessionReleaseDoesNotRewrite() {
        var typist = DictationTypist()
        var screen = ScreenModel("Before: ")
        let words = (0..<200).map { "word\($0)" }
        var maxDelete = 0
        for n in 1..<words.count {
            let committed = words[..<max(0, n - 2)].joined(separator: " ")
            // Draft flips its spelling every pass.
            let draft = words[max(0, n - 2)..<n].map { n % 2 == 0 ? $0.uppercased() : $0 }
                .joined(separator: " ")
            let edit = typist.apply(committed: committed, draft: draft)
            maxDelete = max(maxDelete, edit.deleteCount)
            screen.apply(edit)
        }
        let final = typist.finish(finalText: words.joined(separator: " "))
        screen.apply(final)
        #expect(screen.text == "Before: " + words.joined(separator: " "))
        #expect(maxDelete <= 20)
        #expect(final.deleteCount <= 20)
        #expect(typist.realignCount == 0)
    }

    @Test("Voxtral append deltas type through; new segment never rewrites the old one")
    func appendDeltasAndSegments() {
        var typist = DictationTypist()
        var screen = ScreenModel()
        for delta in ["Hello", " there", "."] {
            screen.apply(typist.append(delta))
        }
        #expect(typist.finish(finalText: "Hello there.").isEmpty)
        typist.startNewSegment()
        screen.apply(typist.append(" Next"))
        screen.apply(typist.finish(finalText: " Next one"))
        #expect(screen.text == "Hello there. Next one")
    }

    @Test("Empty final removes only the draft")
    func emptyFinalRemovesDraftOnly() {
        var typist = DictationTypist()
        var screen = ScreenModel()
        screen.apply(typist.apply(committed: "", draft: "yeah"))
        screen.apply(typist.finish(finalText: ""))
        #expect(screen.text == "")
    }

    @Test("Backspaces count grapheme clusters")
    func graphemeClusters() {
        var typist = DictationTypist()
        var screen = ScreenModel()
        screen.apply(typist.apply(committed: "café", draft: "👍🏽 ok"))
        let edit = typist.apply(committed: "café", draft: "👍🏽 okay")
        #expect(edit == TypingEdit(deleteCount: 0, insert: "ay"))
        screen.apply(edit)
        let swap = typist.apply(committed: "café", draft: "🎉")
        #expect(swap.deleteCount == 6) // "👍🏽 okay" is 6 characters
        screen.apply(swap)
        #expect(screen.text == "café 🎉")
    }
}
