import Testing
@testable import LocalDictation

/// Mirrors `server/tests/test_parakeet_backend.py` LocalAgreementTests so the
/// Swift and Python streamers stay in step.
@Suite("LocalAgreementStreamer")
struct LocalAgreementStreamerTests {
    private static let rate = 16_000
    private static let speechLevel: Float = 0.2

    private static func speech(_ seconds: Double) -> [Float] {
        Array(repeating: speechLevel, count: Int(Double(rate) * seconds))
    }

    /// Fake ASR: pass N returns `script[N]` as words spoken `wordSeconds`
    /// apart from utterance start (times made relative to each pass span).
    private struct Scripted {
        var script: [String]
        var wordSeconds = 0.4
        var passes = 0

        mutating func words(for pass: LocalAgreementStreamer.Pass) -> [TimedWord] {
            let text = script[min(passes, script.count - 1)]
            passes += 1
            let span = Double(pass.samples.count) / Double(LocalAgreementStreamerTests.rate)
            return text.split(separator: " ").enumerated().compactMap { i, word in
                let start = Double(i) * wordSeconds - pass.spanStart
                guard start >= 0, start < span else { return nil }
                return TimedWord(text: String(word), start: start, end: start + wordSeconds * 0.8)
            }
        }
    }

    private static func config(leftContext: Double = 0) -> LocalAgreementStreamer.Config {
        var config = LocalAgreementStreamer.Config()
        config.stepSeconds = 0.5
        config.leftContextSeconds = leftContext
        return config
    }

    private func feed(
        _ streamer: inout LocalAgreementStreamer,
        _ fake: inout Scripted,
        seconds: Double
    ) -> [TranscriptSnapshot] {
        var snapshots: [TranscriptSnapshot] = []
        for _ in 0..<Int((seconds / 0.1).rounded()) {
            if streamer.append(Self.speech(0.1)) {
                let pass = streamer.makePass(final: false)
                if let snapshot = streamer.applyPass(pass, words: fake.words(for: pass)) {
                    snapshots.append(snapshot)
                }
            }
        }
        return snapshots
    }

    private func finalize(_ streamer: inout LocalAgreementStreamer, _ fake: inout Scripted) -> String {
        let pass = streamer.makePass(final: true)
        _ = streamer.applyPass(pass, words: fake.words(for: pass))
        return streamer.finalText()
    }

    @Test("Commits only words two passes agree on; newest word stays draft")
    func commitsAgreedWords() {
        var fake = Scripted(script: ["hello wor", "hello world how", "hello world how are"])
        var streamer = LocalAgreementStreamer(config: Self.config())
        let snaps = feed(&streamer, &fake, seconds: 1.5)
        #expect((snaps[0].committed, snaps[0].draft) == ("", "hello wor"))
        #expect((snaps[1].committed, snaps[1].draft) == ("hello", "world how"))
        #expect((snaps[2].committed, snaps[2].draft) == ("hello world how", "are"))
    }

    @Test("Committed text is append-only even when passes rewrite earlier words")
    func committedAppendOnly() {
        var fake = Scripted(script: ["a b c d", "a b c d e", "x y z d e f", "x y z d e f g"])
        var streamer = LocalAgreementStreamer(config: Self.config())
        let committed = feed(&streamer, &fake, seconds: 2.0).map(\.committed)
        for (earlier, later) in zip(committed, committed.dropFirst()) {
            #expect(later.hasPrefix(earlier))
        }
    }

    @Test("Trailing punctuation waits for the next word to agree")
    func trailingPunctuationWaits() {
        var fake = Scripted(
            script: [
                "pick three priorities.",
                "pick three priorities. Write",
                "pick three priorities, write them",
            ],
            wordSeconds: 0.25
        )
        var streamer = LocalAgreementStreamer(config: Self.config())
        let snaps = feed(&streamer, &fake, seconds: 1.5)
        #expect(snaps[1].committed == "pick three")
        #expect(snaps[2].committed == "pick three")
        #expect(finalize(&streamer, &fake) == "pick three priorities, write them")
    }

    @Test("Punctuation-only flips commit after three passes agree on the words")
    func punctuationFlipCommits() {
        var fake = Scripted(script: ["too long it", "too long, it seems", "too long it seems to", "too long, it seems to go"])
        var streamer = LocalAgreementStreamer(config: Self.config())
        let snaps = feed(&streamer, &fake, seconds: 2.0)
        #expect(snaps[1].committed == "too")
        #expect(snaps[2].committed.hasPrefix("too long"))
    }

    @Test("Invented endings (zero-duration or stacked on one frame) are dropped")
    func inventedTailDropped() {
        let zeroDuration = [
            TimedWord(text: "I", start: 0, end: 0.1),
            TimedWord(text: "would", start: 0.1, end: 0.3),
            TimedWord(text: "have", start: 0.3, end: 0.3),
            TimedWord(text: "go.", start: 0.3, end: 0.3),
        ]
        #expect(LocalAgreementStreamer.dropInventedTail(zeroDuration).map(\.text) == ["I", "would"])
        let stacked = [
            TimedWord(text: "I", start: 0, end: 0.08),
            TimedWord(text: "would", start: 0.1, end: 0.3),
            TimedWord(text: "have", start: 0.56, end: 0.64),
            TimedWord(text: "to", start: 0.56, end: 0.64),
            TimedWord(text: "go.", start: 0.56, end: 0.64),
        ]
        #expect(LocalAgreementStreamer.dropInventedTail(stacked).map(\.text) == ["I", "would"])
        #expect(LocalAgreementStreamer.dropInventedTail(Array(stacked.prefix(3))).count == 3)
    }

    @Test("Volatile view shows the latest full reading, even of committed words")
    func volatileRevisesCommittedWords() {
        var fake = Scripted(
            script: ["it overrides the", "it overrides the text", "it overwrites the text now"],
            wordSeconds: 0.25
        )
        var streamer = LocalAgreementStreamer(config: Self.config())
        let last = feed(&streamer, &fake, seconds: 1.5).last!
        #expect(last.committed.hasPrefix("it overrides"))
        #expect(last.finalized == "")
        #expect(last.volatile == "it overwrites the text now")
    }

    @Test("Trimming finalizes whole sentences behind the anchor")
    func trimFinalizesSentences() {
        let words = (0..<40).map { $0 % 5 == 4 ? "w\($0)." : "w\($0)" }
        var fake = Scripted(script: [words.joined(separator: " ")])
        var config = Self.config(leftContext: 1.0)
        config.softBufferSeconds = 4
        var streamer = LocalAgreementStreamer(config: config)
        var last: TranscriptSnapshot?
        for _ in 0..<160 where streamer.append(Self.speech(0.1)) {
            let pass = streamer.makePass(final: false)
            last = streamer.applyPass(pass, words: fake.words(for: pass)) ?? last
        }
        let finalized = last?.finalized ?? ""
        #expect(!finalized.isEmpty)
        #expect(finalized.hasSuffix("."))
        #expect(last?.committed.hasPrefix(finalized) == true)
    }

    @Test("Finalize commits everything heard")
    func finalizeCommitsEverything() {
        var fake = Scripted(script: ["one two", "one two three", "one two three four"], wordSeconds: 0.2)
        var streamer = LocalAgreementStreamer(config: Self.config())
        _ = feed(&streamer, &fake, seconds: 1.0)
        #expect(finalize(&streamer, &fake) == "one two three four")
    }

    @Test("Silence never reaches the model and finalizes empty")
    func silenceProducesNothing() {
        var streamer = LocalAgreementStreamer(config: Self.config())
        for _ in 0..<10 {
            if streamer.append(Array(repeating: 0, count: 1600)) {
                #expect(streamer.makePass(final: false).samples.isEmpty)
            }
        }
        #expect(streamer.isSilentUtterance)
    }

    @Test("Re-heard committed words with jittered timestamps are not duplicated")
    func reheardTailNotDuplicated() {
        let passes: [[TimedWord]] = [
            [.init(text: "so", start: 0, end: 0.2), .init(text: "I", start: 0.2, end: 0.3), .init(text: "want", start: 0.3, end: 0.6)],
            [.init(text: "so", start: 0, end: 0.2), .init(text: "I", start: 0.2, end: 0.3), .init(text: "want", start: 0.3, end: 0.6), .init(text: "to", start: 0.7, end: 0.8)],
            [.init(text: "so", start: 0.05, end: 0.25), .init(text: "I", start: 0.3, end: 0.45), .init(text: "want", start: 0.5, end: 0.7), .init(text: "to", start: 0.7, end: 0.8), .init(text: "go", start: 0.9, end: 1.1)],
        ]
        var streamer = LocalAgreementStreamer(config: Self.config())
        var index = 0
        for _ in 0..<15 where streamer.append(Self.speech(0.1)) {
            let pass = streamer.makePass(final: false)
            _ = streamer.applyPass(pass, words: passes[min(index, passes.count - 1)])
            index += 1
        }
        let pass = streamer.makePass(final: true)
        _ = streamer.applyPass(pass, words: passes[passes.count - 1])
        #expect(streamer.finalText().split(separator: " ") == ["so", "I", "want", "to", "go"])
    }

    @Test("Buffer trims at sentence ends so passes stay short")
    func bufferTrims() {
        let words = (0..<40).map { $0 % 5 == 4 ? "w\($0)." : "w\($0)" }
        var fake = Scripted(script: [words.joined(separator: " ")])
        var config = Self.config(leftContext: 1.0)
        config.softBufferSeconds = 4
        var streamer = LocalAgreementStreamer(config: config)
        var longest = 0.0
        for _ in 0..<160 where streamer.append(Self.speech(0.1)) {
            let pass = streamer.makePass(final: false)
            longest = max(longest, Double(pass.samples.count) / Double(Self.rate))
            _ = streamer.applyPass(pass, words: fake.words(for: pass))
        }
        #expect(longest < 4 + 1 + 0.6 + 2)
        #expect(streamer.committedText.hasPrefix("w0 w1 w2"))
    }
}
