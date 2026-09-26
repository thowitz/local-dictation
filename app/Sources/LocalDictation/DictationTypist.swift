import Foundation

/// Keystrokes that move the target from what was typed to the next transcript.
struct TypingEdit: Equatable, Sendable {
    var deleteCount = 0
    var insert = ""

    var isEmpty: Bool { deleteCount == 0 && insert.isEmpty }
}

/// Decides what to type for a dictation session, given transcript updates.
///
/// Synthetic keystrokes are blind: the typist can only assume the target shows
/// exactly what it typed. So edits follow two rules that keep a wrong
/// assumption cheap:
///
/// 1. **Committed text is never deleted.** Speech runtimes deliver committed
///    text as append-only; once it is on screen it is *locked*. Only the draft
///    tail typed after it may be backspaced over and corrected.
/// 2. **Corrections are bounded.** A revision needing more than
///    `maxRevision` backspaces is not attempted. The typist *holds* (types
///    nothing) until committed text catches up with the stale draft on screen,
///    then freezes the screen and resumes after the committed words it shows —
///    so nothing is deleted and nothing is typed twice. Only at release, if no
///    alignment exists, does it resume anyway (a repeat beats losing words).
///
/// Positions are `Character` counts (one backspace removes one grapheme).
struct DictationTypist: Sendable {
    static let defaultMaxRevision = 120

    let maxRevision: Int
    /// Exactly what this session has typed (after terminal sanitizing).
    private(set) var typed: [Character] = []
    /// `typed[..<baseTyped]` is frozen and maps to `committed[..<baseTarget]`.
    private var baseTyped = 0
    private var baseTarget = 0
    /// `typed[..<locked]` is committed text: never deleted.
    private(set) var locked = 0
    /// Committed text of the current segment, as last delivered.
    private var committed: [Character] = []
    /// How many bounded-revision fallbacks happened (diagnostics).
    private(set) var realignCount = 0
    /// Waiting for committed text to cover a stale draft we could not delete.
    private var holding = false
    private var holdUpdates = 0
    /// Give up waiting after this many updates and resume (may repeat words).
    private static let maxHoldUpdates = 8

    init(maxRevision: Int = DictationTypist.defaultMaxRevision) {
        self.maxRevision = maxRevision
    }

    var typedText: String { String(typed) }

    /// Absolute snapshot: `committed` (append-only) plus revisable `draft`.
    /// `isFinal` marks the last update of a segment (no more text will come).
    mutating func apply(committed newCommitted: String, draft: String, isFinal: Bool = false) -> TypingEdit {
        let committedChars = Array(newCommitted)
        let target: [Character]
        if draft.isEmpty {
            target = committedChars
        } else if newCommitted.isEmpty {
            target = Array(draft)
        } else {
            target = committedChars + [" "] + Array(draft)
        }
        committed = committedChars

        if baseTarget > committed.count {
            // Committed shrank (a protocol violation): stop mapping into it.
            holding = true
        }

        if holding, !resolveHold(isFinal: isFinal) {
            return TypingEdit()
        }

        var current = typed[baseTyped...]
        var tail = target[min(baseTarget, target.count)...]
        var shared = Self.commonPrefixCount(current, tail)
        if shared < locked - baseTyped || current.count - shared > maxRevision {
            holding = true
            holdUpdates = 0
            realignCount += 1
            guard resolveHold(isFinal: isFinal) else { return TypingEdit() }
            current = typed[baseTyped...]
            tail = target[min(baseTarget, target.count)...]
            shared = Self.commonPrefixCount(current, tail)
        }

        let edit = TypingEdit(
            deleteCount: current.count - shared,
            insert: String(tail.dropFirst(shared))
        )
        typed.removeLast(edit.deleteCount)
        typed.append(contentsOf: edit.insert)
        updateLock()
        return edit
    }

    /// Append-only delta (Voxtral): extends committed text.
    mutating func append(_ delta: String) -> TypingEdit {
        guard !delta.isEmpty else { return TypingEdit() }
        return apply(committed: String(committed) + delta, draft: "")
    }

    /// Voxtral finished an utterance mid-session: later deltas restart from
    /// empty text, so freeze everything typed so far.
    mutating func startNewSegment() {
        freeze(resumeAt: 0)
        holding = false
        committed = []
    }

    /// Final text replaces the current segment (committed + draft).
    mutating func finish(finalText: String) -> TypingEdit {
        apply(committed: finalText, draft: "", isFinal: true)
    }

    // MARK: - Internals

    private mutating func freeze(resumeAt target: Int) {
        baseTyped = typed.count
        baseTarget = target
        locked = typed.count
    }

    /// Try to end a hold: find where the on-screen stale draft ends inside
    /// committed text, freeze the screen, and resume after it.
    private mutating func resolveHold(isFinal: Bool) -> Bool {
        holdUpdates += 1
        let start = min(baseTarget + (locked - baseTyped), committed.count)
        if let resume = staleDraftEnd(searchFrom: start) {
            freeze(resumeAt: resume)
        } else if isFinal || holdUpdates > Self.maxHoldUpdates {
            freeze(resumeAt: wordBoundary(atOrAfter: start))
        } else {
            return false
        }
        holding = false
        holdUpdates = 0
        return true
    }

    private mutating func updateLock() {
        let segment = typed[baseTyped...]
        let committedTail = committed[min(baseTarget, committed.count)...]
        locked = max(locked, baseTyped + Self.commonPrefixCount(segment, committedTail))
    }

    /// Nearest resume index that does not split a word, positioned so the
    /// typed tail starts with its separating space.
    private func wordBoundary(atOrAfter index: Int) -> Int {
        var i = min(index, committed.count)
        while i > 0, i < committed.count, !committed[i - 1].isWhitespace, !committed[i].isWhitespace {
            i += 1
        }
        while i > 0, committed[i - 1].isWhitespace {
            i -= 1
        }
        return i
    }

    /// Index in `committed` just past the words the stale draft shows, found
    /// by matching the draft's last one or two words; `start` if nothing is
    /// stale; nil while committed text has not caught up yet.
    private func staleDraftEnd(searchFrom start: Int) -> Int? {
        let stale = String(typed[locked...])
            .split(whereSeparator: \.isWhitespace)
            .map(Self.normalize)
            .filter { !$0.isEmpty }
        guard !stale.isEmpty else { return wordBoundary(atOrAfter: start) }
        let key = Array(stale.suffix(min(2, stale.count)))

        var words: [(word: String, end: Int)] = []
        var i = start
        while i < committed.count {
            while i < committed.count, committed[i].isWhitespace { i += 1 }
            var j = i
            while j < committed.count, !committed[j].isWhitespace { j += 1 }
            if j > i { words.append((Self.normalize(committed[i..<j]), j)) }
            i = j
        }
        guard words.count >= key.count else { return nil }
        for index in 0...(words.count - key.count)
        where words[index..<(index + key.count)].map(\.word) == key {
            return words[index + key.count - 1].end
        }
        return nil
    }

    static func normalize<S: StringProtocol>(_ word: S) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" })
    }

    static func normalize(_ chars: ArraySlice<Character>) -> String {
        normalize(String(chars))
    }

    static func commonPrefixCount(_ a: ArraySlice<Character>, _ b: ArraySlice<Character>) -> Int {
        var count = 0
        var ia = a.startIndex
        var ib = b.startIndex
        while ia < a.endIndex, ib < b.endIndex, a[ia] == b[ib] {
            count += 1
            ia += 1
            ib += 1
        }
        return count
    }
}
