"""Unit tests for parakeet-mlx backend helpers (no model load)."""

from __future__ import annotations

import unittest
from unittest.mock import MagicMock

import numpy as np

from local_dictation_server.parakeet_backend import ParakeetStreamSession


class FakeResult:
    def __init__(self, text: str):
        self.text = text


class FakeTranscriber:
    def __init__(self):
        self.chunks: list = []
        self._text = ""
        self.script: list[str] | None = None

    def add_audio(self, chunk):
        self.chunks.append(chunk)
        if self.script is not None:
            idx = min(len(self.chunks) - 1, len(self.script) - 1)
            self._text = self.script[idx]
        else:
            self._text = "a" * len(self.chunks)

    @property
    def result(self):
        return FakeResult(self._text)


class FakeStreamCM:
    def __init__(self, transcriber: FakeTranscriber):
        self.transcriber = transcriber

    def __enter__(self):
        return self.transcriber

    def __exit__(self, *args):
        return False


class FakeModel:
    class Pre:
        sample_rate = 16_000

    preprocessor_config = Pre()

    def __init__(self, batch_text: str = ""):
        self.transcriber = FakeTranscriber()
        self._batch_text = batch_text

    def transcribe_stream(self, context_size=(256, 256)):
        return FakeStreamCM(self.transcriber)

    def generate(self, mel):
        return [FakeResult(self._batch_text)]


class ParakeetStreamSessionTests(unittest.TestCase):
    def test_feed_emits_absolute_snapshots(self):
        model = FakeModel()
        session = ParakeetStreamSession(model, chunk_seconds=1.0)
        chunk = np.full(16_000, 0.2, dtype=np.float32)

        e1 = session.feed_audio(chunk)
        self.assertEqual(len(e1), 1)
        self.assertTrue(e1[0].absolute)
        self.assertEqual(e1[0].text, "a")

        e2 = session.feed_audio(chunk)
        self.assertEqual(len(e2), 1)
        self.assertEqual(e2[0].text, "aa")

    def test_no_partial_before_min_samples(self):
        model = FakeModel()
        session = ParakeetStreamSession(model, chunk_seconds=0.2)
        short = np.full(3_200, 0.2, dtype=np.float32)
        self.assertEqual(session.feed_audio(short), [])
        e = session.feed_audio(short)
        self.assertEqual(len(e), 1)
        self.assertEqual(e[0].text, "aa")

    def test_filler_first_emit_suppressed(self):
        model = FakeModel()
        model.transcriber.script = ["yeah", "Hello world"]
        session = ParakeetStreamSession(model, chunk_seconds=1.0)
        chunk = np.full(16_000, 0.2, dtype=np.float32)
        self.assertEqual(session.feed_audio(chunk), [])
        e = session.feed_audio(chunk)
        self.assertEqual(len(e), 1)
        self.assertEqual(e[0].text, "Hello world")

    def test_revision_emits_new_absolute(self):
        model = FakeModel()
        model.transcriber.script = [
            "Hello?",
            "Hello world. This is",
            "Hello world. This is a test.",
        ]
        session = ParakeetStreamSession(model, chunk_seconds=1.0)
        chunk = np.full(16_000, 0.2, dtype=np.float32)
        texts = []
        for _ in range(3):
            for ev in session.feed_audio(chunk):
                texts.append(ev.text)
        self.assertEqual(
            texts,
            [
                "Hello?",
                "Hello world. This is",
                "Hello world. This is a test.",
            ],
        )

    def test_finalize_batch_absolute(self):
        model = FakeModel(batch_text="hello world")
        session = ParakeetStreamSession(model, chunk_seconds=1.0)
        session.utterance = np.full(8_000, 0.2, dtype=np.float32)
        session.pending = np.zeros(0, dtype=np.float32)
        session.emitted_text = "Hello?"
        session.full_text = "Hello?"
        session._batch_transcribe = MagicMock(return_value="hello world")  # type: ignore[method-assign]
        events = session.finalize()
        self.assertEqual(session.full_text, "hello world")
        self.assertEqual(len(events), 1)
        self.assertTrue(events[0].absolute)
        self.assertEqual(events[0].text, "hello world")

    def test_finalize_silence_empty(self):
        model = FakeModel()
        session = ParakeetStreamSession(model, chunk_seconds=1.0)
        session.utterance = np.zeros(8_000, dtype=np.float32)
        session.pending = np.zeros(0, dtype=np.float32)
        session.emitted_text = ""
        session._batch_transcribe = MagicMock(return_value="")  # type: ignore[method-assign]
        self.assertEqual(session.finalize(), [])
        self.assertEqual(session.full_text, "")


if __name__ == "__main__":
    unittest.main()
