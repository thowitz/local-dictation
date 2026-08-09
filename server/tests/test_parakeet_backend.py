"""Unit tests for parakeet-mlx backend helpers (no model load)."""

from __future__ import annotations

import unittest

import numpy as np

from local_dictation_server.parakeet_backend import ParakeetStreamSession


class FakeResult:
    def __init__(self, text: str):
        self.text = text


class FakeTranscriber:
    def __init__(self):
        self.chunks: list = []
        self._text = ""

    def add_audio(self, chunk):
        self.chunks.append(chunk)
        # Grow a stable prefix: "a", "ab", "abc", ...
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

    def __init__(self):
        self.transcriber = FakeTranscriber()

    def transcribe_stream(self, context_size=(256, 256)):
        return FakeStreamCM(self.transcriber)


class ParakeetStreamSessionTests(unittest.TestCase):
    def test_feed_audio_emits_incremental_deltas(self):
        model = FakeModel()
        session = ParakeetStreamSession(model, chunk_seconds=1.0)
        chunk = np.zeros(16_000, dtype=np.float32)

        deltas1 = session.feed_audio(chunk)
        self.assertEqual(deltas1, ["a"])
        self.assertEqual(session.emitted_text, "a")

        deltas2 = session.feed_audio(chunk)
        self.assertEqual(deltas2, ["a"])
        self.assertEqual(session.emitted_text, "aa")

    def test_incremental_delta_prefix(self):
        model = FakeModel()
        session = ParakeetStreamSession(model, chunk_seconds=1.0)
        session.emitted_text = "hello "
        self.assertEqual(session._incremental_delta("hello world"), "world")
        self.assertEqual(session._incremental_delta("hi"), "")

    def test_finalize_flushes_pending(self):
        model = FakeModel()
        session = ParakeetStreamSession(model, chunk_seconds=1.0)
        # Half second — not enough for feed, but finalize flushes.
        half = np.zeros(8_000, dtype=np.float32)
        self.assertEqual(session.feed_audio(half), [])
        deltas = session.finalize()
        self.assertEqual(deltas, ["a"])


if __name__ == "__main__":
    unittest.main()
