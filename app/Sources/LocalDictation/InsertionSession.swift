import Foundation

/// How one dictation session gets text into the focused app.
///
/// Prefers the input method (marked text, like system dictation). Falls back
/// to blind keystrokes through ``DictationTypist`` when the input method is
/// unavailable — but only if it never attached, so nothing is typed twice.
@MainActor
final class InsertionSession {
    enum Route: Equatable {
        case keystrokes
        case inputMethod
    }

    private(set) var route: Route = .keystrokes
    private let textInserter: TextInserter
    private let inputMethod: InputMethodInserter?
    private let typeEdit: ((TypingEdit) -> Void)?
    private var typist = DictationTypist()
    /// Newest full state, so a late fallback can type everything at once.
    private var latestCommitted = ""
    private var latestDraft = ""
    /// Append-only (Voxtral) text of the current segment.
    private var appended = ""

    init(textInserter: TextInserter, inputMethod: InputMethodInserter?, typeEdit: ((TypingEdit) -> Void)?) {
        self.textInserter = textInserter
        self.inputMethod = inputMethod
        self.typeEdit = typeEdit
    }

    var realignCount: Int { typist.realignCount }

    func begin() {
        guard let inputMethod, inputMethod.begin() else { return }
        route = .inputMethod
        inputMethod.onUnavailable = { [weak self] _ in self?.fallBackToKeystrokes() }
    }

    func transcript(_ event: TranscriptEvent) {
        switch event {
        case .append(let delta):
            let text = textInserter.prepared(delta)
            appended += text
            latestCommitted = appended
            latestDraft = ""
            if route == .inputMethod {
                inputMethod?.update(finalized: appended, volatile: "")
            } else {
                type(typist.append(text))
            }
        case .snapshot(let snapshot):
            latestCommitted = textInserter.prepared(snapshot.committed)
            latestDraft = textInserter.prepared(snapshot.draft)
            if route == .inputMethod {
                let view = snapshot.markedTextView
                inputMethod?.update(
                    finalized: textInserter.prepared(view.finalized),
                    volatile: textInserter.prepared(view.volatile)
                )
            } else {
                type(typist.apply(committed: latestCommitted, draft: latestDraft))
            }
        }
    }

    /// Voxtral finished an utterance mid-session; later text restarts empty.
    func newSegment(finalText: String) {
        let text = textInserter.prepared(finalText)
        if route == .inputMethod {
            if !text.isEmpty { inputMethod?.update(finalized: text, volatile: "") }
            inputMethod?.newSegment()
        } else {
            type(typist.finish(finalText: text))
            typist.startNewSegment()
        }
        appended = ""
        latestCommitted = ""
        latestDraft = ""
    }

    func finish(finalText: String) {
        let text = textInserter.prepared(finalText)
        latestCommitted = text
        latestDraft = ""
        if route == .inputMethod, let inputMethod {
            if !inputMethod.finish(finalText: text), !inputMethod.didAttach {
                fallBackToKeystrokes()
            }
        } else {
            type(typist.finish(finalText: text))
        }
    }

    /// Esc / interruption: keep what is shown.
    func cancel() {
        if route == .inputMethod {
            inputMethod?.cancel()
        }
    }

    private func fallBackToKeystrokes() {
        guard route == .inputMethod, inputMethod?.didAttach != true else { return }
        route = .keystrokes
        type(typist.apply(committed: latestCommitted, draft: latestDraft))
    }

    private func type(_ edit: TypingEdit) {
        guard !edit.isEmpty else { return }
        if let typeEdit {
            typeEdit(edit)
        } else {
            textInserter.perform(edit)
        }
    }
}
