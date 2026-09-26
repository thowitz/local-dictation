"""Streaming dictation over an offline (full-attention) ASR model.

Parakeet TDT is trained on whole utterances. Its chunked "streaming" mode
re-decodes a long draft window with truncated context, so early words keep
changing and degrade. Instead, this module re-transcribes a short trailing
buffer at a fixed cadence and commits the words two consecutive passes agree
on (LocalAgreement-2, Macháček et al. 2023).

- ``committed`` text is append-only: once a word is committed it never
  changes, so the client can type it and forget it.
- ``draft`` is the short unagreed tail (typically the last word or two) that
  the client may revise.
- The buffer is trimmed at committed sentence ends (or, if speech never pauses,
  at the last committed word) so every pass stays short.
"""

from __future__ import annotations

import re
from collections.abc import Callable, Sequence
from dataclasses import dataclass

import numpy as np

SILENCE_PEAK = 0.012
SILENCE_RMS = 0.004
_FILLER_ONLY = re.compile(
    r"^(yeah|yes|yep|yup|mm+|mhm+|uh+|um+|hmm+|ah+|oh+|mm-hmm)[.!?,\s]*$",
    re.IGNORECASE,
)
_SENTENCE_END = re.compile(r"[.!?][\"')\]]*$")
_MIN_WORD_SECONDS = 0.02
_TRAILING_PUNCT = re.compile(r"[.!?,;:][\"')\]]*$")


@dataclass(frozen=True)
class TimedWord:
    """One recognized word; times are seconds from the start of its input."""

    text: str
    start: float
    end: float

    def shifted(self, offset: float) -> TimedWord:
        return TimedWord(self.text, self.start + offset, self.end + offset)


@dataclass(frozen=True)
class TranscriptSnapshot:
    """One live update, in two views of the same speech.

    ``committed`` + ``draft`` is for blind keystroke typing: committed text is
    append-only and only the short draft tail may change. ``finalized`` +
    ``volatile`` is for marked-text insertion (input method): finalized text
    will never be re-transcribed; volatile is the model's latest full reading
    of the current phrase and may be replaced wholesale.
    """

    committed: str
    draft: str
    finalized: str = ""
    volatile: str = ""


Transcribe = Callable[[np.ndarray], Sequence[TimedWord]]


def normalize(word: str) -> str:
    return re.sub(r"[^\w']", "", word.lower())


def render(words: Sequence[TimedWord]) -> str:
    return " ".join(w.text for w in words)


def drop_invented_tail(words: list[TimedWord]) -> list[TimedWord]:
    """Remove the ending a decoder invents when audio stops mid-word.

    Cut-off audio makes TDT emit a plausible continuation ("I would have to
    go to the house.") as tokens stacked on the final frame: zero duration
    (parakeet-mlx) or several words sharing one start time (FluidAudio).
    Real words advance by at least one encoder frame.
    """
    words = list(words)
    while words and words[-1].end - words[-1].start < _MIN_WORD_SECONDS:
        words.pop()
    if len(words) >= 2:
        last_start = words[-1].start
        stacked = 0
        for w in reversed(words):
            if last_start - w.start >= _MIN_WORD_SECONDS:
                break
            stacked += 1
        if stacked >= 2:
            words = words[:-stacked]
    return words


def drop_covered(
    hyp: list[TimedWord], reference: Sequence[TimedWord]
) -> list[TimedWord]:
    """Words of ``hyp`` not already in ``reference`` (a prefix of the utterance)."""
    if not reference:
        return list(hyp)
    cut = reference[-1].end
    hyp = [w for w in hyp if (w.start + w.end) / 2 >= cut]
    # Word timestamps jitter between passes; also drop a re-heard tail.
    tail = [normalize(w.text) for w in reference[-4:]]
    head = [normalize(w.text) for w in hyp[:4]]
    for k in range(min(len(tail), len(head)), 0, -1):
        if tail[-k:] == head[:k]:
            return hyp[k:]
    return hyp


def is_silence(audio: np.ndarray) -> bool:
    if audio.size == 0:
        return True
    peak = float(np.max(np.abs(audio)))
    rms = float(np.sqrt(np.mean(np.square(audio), dtype=np.float64)))
    return peak < SILENCE_PEAK and rms < SILENCE_RMS


class LocalAgreementStreamer:
    """One utterance: feed PCM, get snapshots, finalize once."""

    def __init__(
        self,
        transcribe: Transcribe,
        *,
        sample_rate: int = 16_000,
        step_seconds: float = 0.5,
        left_context_seconds: float = 1.5,
        soft_buffer_seconds: float = 10.0,
        hard_buffer_seconds: float = 20.0,
        final_pad_seconds: float = 0.5,
    ):
        self._transcribe = transcribe
        self.sample_rate = sample_rate
        self.step_samples = max(1, int(sample_rate * max(0.2, step_seconds)))
        self.left_context = left_context_seconds
        self.soft_buffer = soft_buffer_seconds
        self.hard_buffer = max(hard_buffer_seconds, soft_buffer_seconds)
        self.final_pad = final_pad_seconds

        # Audio kept from ``_offset`` samples into the utterance.
        self._audio = np.zeros(0, dtype=np.float32)
        self._offset = 0
        self._samples_since_pass = 0
        self._peak = 0.0
        self._anchor = 0.0  # seconds; passes only look for new words after this
        self.committed: list[TimedWord] = []
        self._draft: list[TimedWord] = []
        self._older_draft: list[TimedWord] = []
        # committed[:_finalized_count] ends at or before the anchor: no pass
        # hears it again, so it can be inserted permanently.
        self._finalized_count = 0
        # Latest pass that heard speech (silent passes keep the phrase shown).
        self._last_heard: list[TimedWord] = []
        self._last_snapshot = TranscriptSnapshot("", "")

    # MARK: - Public

    @property
    def duration(self) -> float:
        return (self._offset + self._audio.size) / self.sample_rate

    @property
    def committed_text(self) -> str:
        return render(self.committed)

    def add_audio(self, samples: np.ndarray) -> TranscriptSnapshot | None:
        """Append PCM; run a pass every ``step_seconds`` of new audio."""
        if samples.size == 0:
            return None
        samples = np.ascontiguousarray(samples, dtype=np.float32).reshape(-1)
        self._audio = np.concatenate([self._audio, samples])
        self._peak = max(self._peak, float(np.max(np.abs(samples))))
        self._samples_since_pass += samples.size
        if self._samples_since_pass < self.step_samples:
            return None
        self._samples_since_pass = 0
        return self._publish(self._pass(final=False))

    def finalize(self) -> str:
        """Commit everything heard; returns the full utterance text."""
        if self._offset == 0 and is_silence(self._audio):
            return ""
        self._pass(final=True)
        text = self.committed_text
        if _FILLER_ONLY.match(text) and self._peak < 0.05:
            # Quiet "yeah"/"mm" is the classic hallucination on near-silence.
            return ""
        return text

    # MARK: - Passes

    def _pass(self, *, final: bool) -> TranscriptSnapshot:
        now = self.duration
        span_start = max(
            self._offset / self.sample_rate, self._anchor - self.left_context
        )
        new_audio = self._slice(self._anchor, now)
        hyp: list[TimedWord] = []
        if not is_silence(new_audio):
            span = self._slice(span_start, now)
            if final and self.final_pad > 0:
                pad = np.zeros(int(self.sample_rate * self.final_pad), dtype=np.float32)
                span = np.concatenate([span, pad])
            hyp = [w.shifted(span_start) for w in self._transcribe(span) if w.text]
            if final:
                hyp = [w for w in hyp if w.start < now]
            else:
                hyp = drop_invented_tail(hyp)
            self._last_heard = hyp
        hyp = drop_covered(hyp, self.committed)

        if final:
            agreed = len(hyp)
        else:
            agreed = 0
            for i, cur in enumerate(hyp):
                prev = self._draft[i] if i < len(self._draft) else None
                older = self._older_draft[i] if i < len(self._older_draft) else None
                if prev is not None and prev.text == cur.text:
                    agreed += 1
                    continue
                # Only punctuation/case flips between passes: after three
                # passes agree on the words, commit the newest spelling.
                key = normalize(cur.text)
                if (
                    prev is not None
                    and older is not None
                    and normalize(prev.text) == key
                    and normalize(older.text) == key
                ):
                    agreed += 1
                    continue
                break
            # The newest word may be cut mid-syllable: never commit it yet.
            agreed = min(agreed, max(0, len(hyp) - 1))
            # A pause makes both passes guess "word." — trust trailing
            # punctuation only once the following word agrees too.
            if agreed and _TRAILING_PUNCT.search(hyp[agreed - 1].text):
                agreed -= 1
        self.committed.extend(hyp[:agreed])
        # Previous pass's draft realigned to the new draft's start (the words
        # just committed drop off its front).
        self._older_draft = self._draft[agreed:]
        self._draft = hyp[agreed:]
        if final:
            self._finalized_count = len(self.committed)
            volatile: list[TimedWord] = []
        else:
            self._trim(now)
            self._finalized_count = sum(
                1 for w in self.committed if w.end <= self._anchor
            )
            finalized = self.committed[: self._finalized_count]
            volatile = drop_covered(self._last_heard, finalized)
        return TranscriptSnapshot(
            self.committed_text,
            render(self._draft),
            render(self.committed[: self._finalized_count]),
            render(volatile),
        )

    def _trim(self, now: float) -> None:
        """Advance the anchor so passes stay short; drop audio behind it."""
        if not self.committed or now - self._anchor <= self.soft_buffer:
            return
        new_anchor = None
        for word in reversed(self.committed):
            if word.end <= self._anchor:
                break
            if _SENTENCE_END.search(word.text):
                new_anchor = word.end
                break
        if new_anchor is None and now - self._anchor > self.hard_buffer:
            new_anchor = self.committed[-1].end
        if new_anchor is None:
            return
        self._anchor = new_anchor
        keep_from = max(0, int((new_anchor - self.left_context) * self.sample_rate))
        drop = keep_from - self._offset
        if drop > 0:
            self._audio = self._audio[drop:]
            self._offset = keep_from

    def _slice(self, start_s: float, end_s: float) -> np.ndarray:
        a = max(0, int(start_s * self.sample_rate) - self._offset)
        b = max(a, int(end_s * self.sample_rate) - self._offset)
        return self._audio[a:b]

    def _publish(self, snapshot: TranscriptSnapshot) -> TranscriptSnapshot | None:
        if snapshot == self._last_snapshot:
            return None
        self._last_snapshot = snapshot
        return snapshot
