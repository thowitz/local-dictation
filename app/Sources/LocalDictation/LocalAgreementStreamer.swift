import Foundation

/// One recognized word; times are seconds (relative to its pass input until
/// the streamer shifts them onto the utterance timeline).
struct TimedWord: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// One live transcript update, in two views of the same speech:
///
/// - `committed` + `draft` — for blind keystroke typing: committed text is
///   append-only (words two passes agreed on) and only the short draft tail
///   may be revised.
/// - `finalized` + `volatile` — for marked-text insertion (input method):
///   finalized text will never be re-transcribed; volatile is the model's
///   latest full reading of the current phrase and may be replaced wholesale.
///   `nil` when a runtime only provides the committed/draft view.
struct TranscriptSnapshot: Equatable, Sendable {
    var committed: String
    var draft: String
    var finalized: String? = nil
    var volatile: String? = nil

    /// Finalized/volatile view, derived from committed/draft when absent.
    var markedTextView: (finalized: String, volatile: String) {
        (finalized ?? committed, volatile ?? draft)
    }
}

/// Streaming dictation over an offline (full-attention) ASR model.
///
/// Swift port of `server/src/local_dictation_server/local_agreement.py` — keep
/// the two in step. Parakeet TDT is trained on whole utterances, so rather than
/// chunked decoding this re-transcribes a short trailing buffer every
/// `stepSeconds` and commits the words two consecutive passes agree on
/// (LocalAgreement-2). Committed words never change; the draft is the short
/// unagreed tail. The buffer is trimmed at committed sentence ends so passes
/// stay short.
///
/// Transcription is async and lives outside this type: call ``append(_:)``,
/// and when it returns true run ``makePass(final:)``'s samples through the
/// model and hand the words to ``applyPass(_:words:)``.
struct LocalAgreementStreamer: Sendable {
    struct Config: Sendable {
        var sampleRate = 16_000
        var stepSeconds = 0.5
        var leftContextSeconds = 1.5
        var softBufferSeconds = 10.0
        var hardBufferSeconds = 20.0
        var finalPadSeconds = 0.5
    }

    /// Audio to transcribe for one pass.
    struct Pass: Sendable {
        /// Empty when the new audio is silent (no model call needed).
        var samples: [Float]
        var spanStart: Double
        var now: Double
        var isFinal: Bool
    }

    static let silencePeak: Float = 0.012
    static let silenceRMS: Float = 0.004
    static let minWordSeconds = 0.02

    let config: Config
    private var audio: [Float] = []
    /// Samples dropped from the front of `audio` (utterance timeline offset).
    private var offset = 0
    private var samplesSincePass = 0
    private var peak: Float = 0
    private var anchor = 0.0
    private(set) var committed: [TimedWord] = []
    private var draft: [TimedWord] = []
    private var olderDraft: [TimedWord] = []
    /// `committed[..<finalizedCount]` ends at or before `anchor`: no pass
    /// will hear it again, so it can be inserted permanently.
    private var finalizedCount = 0
    /// Latest pass that heard speech (silent passes keep the phrase shown).
    private var lastHeard: [TimedWord] = []
    private var lastSnapshot = TranscriptSnapshot(committed: "", draft: "")

    init(config: Config = Config()) {
        var config = config
        config.stepSeconds = max(0.2, config.stepSeconds)
        config.hardBufferSeconds = max(config.hardBufferSeconds, config.softBufferSeconds)
        self.config = config
    }

    var duration: Double { Double(offset + audio.count) / Double(config.sampleRate) }
    var committedText: String { Self.render(committed) }
    var hasAudio: Bool { offset + audio.count > 0 }

    /// Append PCM. Returns true when a live pass is due.
    mutating func append(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        audio.append(contentsOf: samples)
        for s in samples { peak = max(peak, abs(s)) }
        samplesSincePass += samples.count
        let step = Int(Double(config.sampleRate) * config.stepSeconds)
        guard samplesSincePass >= step else { return false }
        samplesSincePass = 0
        return true
    }

    func makePass(final: Bool) -> Pass {
        let now = duration
        let spanStart = max(Double(offset) / Double(config.sampleRate), anchor - config.leftContextSeconds)
        guard !Self.isSilence(slice(from: anchor, to: now)) else {
            return Pass(samples: [], spanStart: spanStart, now: now, isFinal: final)
        }
        var samples = Array(slice(from: spanStart, to: now))
        if final, config.finalPadSeconds > 0 {
            samples.append(contentsOf: repeatElement(0, count: Int(Double(config.sampleRate) * config.finalPadSeconds)))
        }
        return Pass(samples: samples, spanStart: spanStart, now: now, isFinal: final)
    }

    /// Fold a pass's words (times relative to `pass.samples`) into the
    /// transcript. Returns a snapshot when the visible text changed.
    mutating func applyPass(_ pass: Pass, words: [TimedWord]) -> TranscriptSnapshot? {
        var hyp = words
            .filter { !$0.text.isEmpty }
            .map { TimedWord(text: $0.text, start: $0.start + pass.spanStart, end: $0.end + pass.spanStart) }
        if pass.isFinal {
            hyp = hyp.filter { $0.start < pass.now }
        } else {
            hyp = Self.dropInventedTail(hyp)
        }
        if !pass.samples.isEmpty {
            lastHeard = hyp
        }
        hyp = Self.dropCovered(hyp, by: committed[...])

        var agreed = 0
        if pass.isFinal {
            agreed = hyp.count
        } else {
            for (i, current) in hyp.enumerated() {
                let previous = i < draft.count ? draft[i] : nil
                let older = i < olderDraft.count ? olderDraft[i] : nil
                if let previous, previous.text == current.text {
                    agreed += 1
                    continue
                }
                // Only punctuation/case flips between passes: after three
                // passes agree on the words, commit the newest spelling.
                let key = Self.normalize(current.text)
                if let previous, let older,
                   Self.normalize(previous.text) == key, Self.normalize(older.text) == key
                {
                    agreed += 1
                    continue
                }
                break
            }
            // The newest word may be cut mid-syllable: never commit it yet.
            agreed = min(agreed, max(0, hyp.count - 1))
            // A pause makes both passes guess "word." — trust trailing
            // punctuation only once the following word agrees too.
            if agreed > 0, Self.hasTrailingPunctuation(hyp[agreed - 1].text) {
                agreed -= 1
            }
        }
        committed.append(contentsOf: hyp[..<agreed])
        olderDraft = Array(draft.dropFirst(agreed))
        draft = Array(hyp[agreed...])
        if pass.isFinal {
            finalizedCount = committed.count
        } else {
            trim(now: pass.now)
            finalizedCount = committed.prefix { $0.end <= anchor }.count
        }
        let volatile = pass.isFinal ? [] : Self.dropCovered(lastHeard, by: committed[..<finalizedCount])
        let snapshot = TranscriptSnapshot(
            committed: committedText,
            draft: Self.render(draft),
            finalized: Self.render(Array(committed[..<finalizedCount])),
            volatile: Self.render(volatile)
        )
        guard snapshot != lastSnapshot else { return nil }
        lastSnapshot = snapshot
        return snapshot
    }

    /// Final text once ``applyPass(_:words:)`` has run the final pass.
    func finalText() -> String {
        let text = committedText
        if Self.isFillerOnly(text), peak < 0.05 {
            // Quiet "yeah"/"mm" is the classic hallucination on near-silence.
            return ""
        }
        return text
    }

    /// True when the whole utterance so far is silence (skip the final pass).
    var isSilentUtterance: Bool {
        offset == 0 && Self.isSilence(audio[...])
    }

    // MARK: - Internals

    /// Words of `hyp` not already in `reference` (a prefix of the utterance).
    static func dropCovered(_ hyp: [TimedWord], by reference: ArraySlice<TimedWord>) -> [TimedWord] {
        guard let last = reference.last else { return hyp }
        let kept = hyp.filter { ($0.start + $0.end) / 2 >= last.end }
        // Word timestamps jitter between passes; also drop a re-heard tail.
        let tail = reference.suffix(4).map { Self.normalize($0.text) }
        let head = kept.prefix(4).map { Self.normalize($0.text) }
        for k in stride(from: min(tail.count, head.count), through: 1, by: -1) {
            if Array(tail.suffix(k)) == Array(head.prefix(k)) {
                return Array(kept.dropFirst(k))
            }
        }
        return kept
    }

    private mutating func trim(now: Double) {
        guard !committed.isEmpty, now - anchor > config.softBufferSeconds else { return }
        var newAnchor: Double?
        for word in committed.reversed() {
            if word.end <= anchor { break }
            if Self.endsSentence(word.text) {
                newAnchor = word.end
                break
            }
        }
        if newAnchor == nil, now - anchor > config.hardBufferSeconds {
            newAnchor = committed.last?.end
        }
        guard let newAnchor else { return }
        anchor = newAnchor
        let keepFrom = max(0, Int((newAnchor - config.leftContextSeconds) * Double(config.sampleRate)))
        let drop = keepFrom - offset
        if drop > 0 {
            audio.removeFirst(min(drop, audio.count))
            offset = keepFrom
        }
    }

    private func slice(from start: Double, to end: Double) -> ArraySlice<Float> {
        let rate = Double(config.sampleRate)
        let a = min(audio.count, max(0, Int(start * rate) - offset))
        let b = min(audio.count, max(a, Int(end * rate) - offset))
        return audio[a..<b]
    }

    // MARK: - Text helpers

    static func render(_ words: [TimedWord]) -> String {
        words.map(\.text).joined(separator: " ")
    }

    static func normalize(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" })
    }

    static func isSilence(_ samples: ArraySlice<Float>) -> Bool {
        guard !samples.isEmpty else { return true }
        var peak: Float = 0
        var sumSquares: Double = 0
        for s in samples {
            peak = max(peak, abs(s))
            sumSquares += Double(s) * Double(s)
        }
        let rms = Float((sumSquares / Double(samples.count)).squareRoot())
        return peak < silencePeak && rms < silenceRMS
    }

    /// Remove the ending a decoder invents when audio stops mid-word: tokens
    /// stacked on the final frame (zero duration, or several words sharing one
    /// start time). Real words advance by at least one encoder frame.
    static func dropInventedTail(_ words: [TimedWord]) -> [TimedWord] {
        var words = words
        while let last = words.last, last.end - last.start < minWordSeconds {
            words.removeLast()
        }
        guard words.count >= 2, let lastStart = words.last?.start else { return words }
        var stacked = 0
        for word in words.reversed() {
            if lastStart - word.start >= minWordSeconds { break }
            stacked += 1
        }
        if stacked >= 2 {
            words.removeLast(stacked)
        }
        return words
    }

    static func hasTrailingPunctuation(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]"))
        guard let last = trimmed.last else { return false }
        return ".!?,;:".contains(last)
    }

    static func endsSentence(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]"))
        guard let last = trimmed.last else { return false }
        return ".!?".contains(last)
    }

    static func isFillerOnly(_ text: String) -> Bool {
        text.range(
            of: #"^(yeah|yes|yep|yup|mm+|mhm+|uh+|um+|hmm+|ah+|oh+|mm-hmm)[.!?,\s]*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
