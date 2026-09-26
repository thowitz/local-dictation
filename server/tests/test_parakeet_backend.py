"""Unit tests for the parakeet-mlx backend and LocalAgreement streaming (no model load)."""

from __future__ import annotations

import unittest
from dataclasses import dataclass

import numpy as np

from local_dictation_server.local_agreement import (
    LocalAgreementStreamer,
    TimedWord,
    drop_invented_tail,
)
from local_dictation_server.parakeet_backend import (
    ParakeetStreamSession,
    tokens_to_words,
)

SR = 16_000
SPEECH = 0.2  # constant "speech" level: well above the silence gate


def speech(seconds: float) -> np.ndarray:
    return np.full(int(SR * seconds), SPEECH, dtype=np.float32)


class ScriptedTranscriber:
    """Fake ASR: pass N returns script[N] as evenly spaced words over the span.

    Each script entry is the full text the model "hears" for the utterance so
    far; words are timed as if spoken 0.4 s apart from utterance start, so the
    streamer's time-based bookkeeping behaves like the real model.
    """

    def __init__(self, script: list[str], word_seconds: float = 0.4):
        self.script = script
        self.word_seconds = word_seconds
        self.calls: list[tuple[int, float]] = []  # (samples, span offset guess)
        self.offset = 0.0  # streamer tells us nothing; tests set it via hook

    def __call__(self, audio: np.ndarray) -> list[TimedWord]:
        index = min(len(self.calls), len(self.script) - 1)
        self.calls.append((audio.size, self.offset))
        words = self.script[index].split()
        span = audio.size / SR
        out = []
        for i, w in enumerate(words):
            start = i * self.word_seconds - self.offset
            if start < 0 or start >= span:
                continue
            out.append(TimedWord(w, start, start + self.word_seconds * 0.8))
        return out


class LocalAgreementTests(unittest.TestCase):
    def feed(self, streamer, seconds, step=0.1):
        snaps = []
        for _ in range(round(seconds / step)):
            snap = streamer.add_audio(speech(step))
            if snap is not None:
                snaps.append(snap)
        return snaps

    def test_commits_only_words_two_passes_agree_on(self):
        fake = ScriptedTranscriber(
            [
                "hello wor",
                "hello world how",
                "hello world how are",
            ]
        )
        s = LocalAgreementStreamer(fake, step_seconds=0.5, left_context_seconds=0)
        snaps = self.feed(s, 1.5)
        self.assertEqual((snaps[0].committed, snaps[0].draft), ("", "hello wor"))
        # "hello" agreed; "world" is new; newest word never commits.
        self.assertEqual((snaps[1].committed, snaps[1].draft), ("hello", "world how"))
        # "world how" agreed; "are" is the newest word.
        self.assertEqual(
            (snaps[2].committed, snaps[2].draft), ("hello world how", "are")
        )

    def test_committed_text_is_append_only(self):
        fake = ScriptedTranscriber(
            ["a b c d", "a b c d e", "x y z d e f", "x y z d e f g"]
        )
        s = LocalAgreementStreamer(fake, step_seconds=0.5, left_context_seconds=0)
        committed = [snap.committed for snap in self.feed(s, 2.0)]
        for earlier, later in zip(committed, committed[1:]):
            self.assertTrue(later.startswith(earlier), (earlier, later))

    def test_trailing_punctuation_waits_for_next_word(self):
        fake = ScriptedTranscriber(
            [
                "pick three priorities.",
                "pick three priorities. Write",
                "pick three priorities, write them",
            ],
            word_seconds=0.25,
        )
        s = LocalAgreementStreamer(fake, step_seconds=0.5, left_context_seconds=0)
        snaps = self.feed(s, 1.5)
        # "priorities." agreed twice but must not lock before the next word does.
        self.assertEqual(snaps[1].committed, "pick three")
        self.assertEqual(snaps[2].committed, "pick three")
        self.assertEqual(s.finalize(), "pick three priorities, write them")

    def test_punctuation_flip_commits_after_three_passes(self):
        fake = ScriptedTranscriber(
            [
                "too long it",
                "too long, it seems",
                "too long it seems to",
                "too long, it seems to go",
            ]
        )
        s = LocalAgreementStreamer(fake, step_seconds=0.5, left_context_seconds=0)
        snaps = self.feed(s, 2.0)
        self.assertEqual(snaps[1].committed, "too")
        # Pass 3: "long" vs "long," flipped but three passes agree on the word.
        self.assertTrue(snaps[2].committed.startswith("too long"), snaps[2])

    def test_zero_duration_tail_words_are_dropped(self):
        def transcribe(audio):
            return [
                TimedWord("I", 0.0, 0.1),
                TimedWord("would", 0.1, 0.3),
                TimedWord("have", 0.3, 0.3),
                TimedWord("to", 0.3, 0.3),
                TimedWord("go.", 0.3, 0.3),
            ]

        s = LocalAgreementStreamer(transcribe, step_seconds=0.5)
        snap = self.feed(s, 0.5)[0]
        self.assertEqual((snap.committed, snap.draft), ("", "I would"))

    def test_words_stacked_on_one_frame_are_dropped(self):
        # FluidAudio gives every token >= one frame, so invented endings show
        # up as several words sharing the last start time instead.
        words = [
            TimedWord("I", 0.0, 0.08),
            TimedWord("would", 0.1, 0.3),
            TimedWord("have", 0.56, 0.64),
            TimedWord("to", 0.56, 0.64),
            TimedWord("go.", 0.56, 0.64),
        ]
        self.assertEqual([w.text for w in drop_invented_tail(words)], ["I", "would"])
        # A single final word is normal and stays.
        self.assertEqual(len(drop_invented_tail(words[:3])), 3)

    def test_volatile_is_latest_full_reading_until_finalized(self):
        # Pass 3 revises an already-committed word; the committed view keeps
        # it, but the volatile view shows the latest reading (marked text).
        fake = ScriptedTranscriber(
            ["it overrides the", "it overrides the text", "it overwrites the text now"],
            word_seconds=0.25,
        )
        s = LocalAgreementStreamer(fake, step_seconds=0.5, left_context_seconds=0)
        snaps = self.feed(s, 1.5)
        self.assertTrue(snaps[-1].committed.startswith("it overrides"))
        self.assertEqual(snaps[-1].finalized, "")
        self.assertEqual(snaps[-1].volatile, "it overwrites the text now")

    def test_silent_pass_keeps_volatile_phrase(self):
        fake = ScriptedTranscriber(["hello there", "hello there friend"])
        s = LocalAgreementStreamer(fake, step_seconds=0.5, left_context_seconds=0)
        self.feed(s, 1.0)
        snap = None
        for _ in range(5):
            snap = s.add_audio(np.zeros(1600, dtype=np.float32)) or snap
        # Silence: nothing new is heard, so the phrase must stay on screen.
        self.assertIsNone(snap)
        self.assertEqual(s._last_heard[-1].text, "friend")

    def test_trim_finalizes_sentences_behind_the_anchor(self):
        words = [f"w{i}." if i % 5 == 4 else f"w{i}" for i in range(40)]
        fake = ScriptedTranscriber([" ".join(words)])
        s = LocalAgreementStreamer(
            fake, step_seconds=0.5, left_context_seconds=1.0, soft_buffer_seconds=4.0
        )
        last = None
        for _ in range(160):
            last = s.add_audio(speech(0.1)) or last
            fake.offset = s._offset / SR
        self.assertTrue(last.finalized)
        self.assertTrue(last.committed.startswith(last.finalized))
        self.assertTrue(last.finalized.endswith("."))
        self.assertEqual(
            (last.finalized + " " + last.volatile).split()[:3], ["w0", "w1", "w2"]
        )

    def test_finalize_commits_everything(self):
        fake = ScriptedTranscriber(
            ["one two", "one two three", "one two three four"], word_seconds=0.2
        )
        s = LocalAgreementStreamer(fake, step_seconds=0.5, left_context_seconds=0)
        self.feed(s, 1.0)
        self.assertEqual(s.finalize(), "one two three four")

    def test_silence_produces_nothing(self):
        calls = []

        def transcribe(audio):
            calls.append(audio.size)
            return [TimedWord("Yeah.", 0.0, 0.3)]

        s = LocalAgreementStreamer(transcribe, step_seconds=0.5)
        for _ in range(10):
            self.assertIsNone(s.add_audio(np.zeros(1600, dtype=np.float32)))
        self.assertEqual(s.finalize(), "")
        self.assertEqual(calls, [])

    def test_quiet_filler_only_final_is_dropped(self):
        s = LocalAgreementStreamer(
            lambda audio: [TimedWord("Yeah.", 0.0, 0.3)], step_seconds=0.5
        )
        s.add_audio(np.full(8000, 0.02, dtype=np.float32))
        self.assertEqual(s.finalize(), "")

    def test_rehead_committed_tail_is_not_duplicated(self):
        # Second pass re-hears the committed words with shifted timestamps.
        passes = [
            [
                TimedWord("so", 0.0, 0.2),
                TimedWord("I", 0.2, 0.3),
                TimedWord("want", 0.3, 0.6),
            ],
            [
                TimedWord("so", 0.0, 0.2),
                TimedWord("I", 0.2, 0.3),
                TimedWord("want", 0.3, 0.6),
                TimedWord("to", 0.7, 0.8),
            ],
            [
                TimedWord("so", 0.05, 0.25),
                TimedWord("I", 0.3, 0.45),
                TimedWord("want", 0.5, 0.7),
                TimedWord("to", 0.7, 0.8),
                TimedWord("go", 0.9, 1.1),
            ],
        ]
        calls = []

        def transcribe(audio):
            calls.append(1)
            return passes[min(len(calls) - 1, len(passes) - 1)]

        s = LocalAgreementStreamer(transcribe, step_seconds=0.5, left_context_seconds=0)
        self.feed(s, 1.5)
        self.assertEqual(s.finalize().split(), ["so", "I", "want", "to", "go"])

    def test_buffer_trims_at_sentence_end_and_bounds_pass_length(self):
        # 40 words at 0.4 s each = 16 s; a sentence ends every 5 words.
        words = [f"w{i}." if i % 5 == 4 else f"w{i}" for i in range(40)]
        sizes = []

        def transcribe(audio):
            sizes.append(audio.size / SR)
            return []

        fake = ScriptedTranscriber([" ".join(words)])
        s = LocalAgreementStreamer(
            fake, step_seconds=0.5, left_context_seconds=1.0, soft_buffer_seconds=4.0
        )
        for _ in range(160):
            s.add_audio(speech(0.1))
            fake.offset = s._offset / SR
        longest = max(size for size, _ in fake.calls) / SR
        self.assertLess(longest, 4.0 + 1.0 + 0.6 + 2.0)
        self.assertGreater(s._anchor, 0)
        self.assertTrue(s.committed_text.startswith("w0 w1 w2"))


@dataclass
class Tok:
    text: str
    start: float
    end: float


class TokensToWordsTests(unittest.TestCase):
    def test_groups_subword_tokens(self):
        toks = [
            Tok(" Hel", 0.0, 0.1),
            Tok("lo", 0.1, 0.2),
            Tok(" world", 0.3, 0.5),
            Tok(".", 0.5, 0.5),
        ]
        self.assertEqual(
            tokens_to_words(toks),
            [TimedWord("Hello", 0.0, 0.2), TimedWord("world.", 0.3, 0.5)],
        )

    def test_first_token_without_space_starts_a_word(self):
        self.assertEqual(
            tokens_to_words([Tok("Hi", 0.0, 0.1)]), [TimedWord("Hi", 0.0, 0.1)]
        )


class ParakeetStreamSessionTests(unittest.TestCase):
    def test_emits_snapshot_events_and_done(self):
        fake = ScriptedTranscriber(["hello", "hello world", "hello world again"])
        session = ParakeetStreamSession(fake, step_seconds=0.5)
        events = [session.feed_audio(speech(0.5)) for _ in range(3)]
        self.assertEqual(
            events[1],
            {
                "type": "transcript.snapshot",
                "committed": "hello",
                "draft": "world",
                "finalized": "",
                "volatile": "hello world",
            },
        )
        final = session.finalize()
        self.assertEqual(final[0]["type"], "transcript.snapshot")
        self.assertEqual(final[0]["draft"], "")
        self.assertEqual(
            final[1],
            {"type": "response.audio_transcript.done", "text": final[0]["committed"]},
        )
        self.assertTrue(final[0]["committed"].startswith("hello world"))

    def test_finalize_resets_for_next_utterance(self):
        fake = ScriptedTranscriber(["one"])
        session = ParakeetStreamSession(fake, step_seconds=0.5)
        session.feed_audio(speech(0.5))
        session.finalize()
        self.assertEqual(session.streamer.duration, 0)
        self.assertEqual(session.streamer.committed_text, "")


if __name__ == "__main__":
    unittest.main()
