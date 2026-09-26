"""Parakeet MLX realtime backend (OpenAI Realtime subset).

Parakeet TDT is an offline model, so live text comes from
:class:`~local_dictation_server.local_agreement.LocalAgreementStreamer`:
short full-attention passes over a trailing buffer, committing the words two
passes agree on. ``parakeet-mlx``'s own ``transcribe_stream`` is not used — it
re-decodes a ~20 s draft window with truncated context, which rewrites (and
degrades) text the user has already seen.

Protocol matches the Voxtral path in server.py plus one event:

- ``transcript.snapshot`` ``{committed, draft, finalized, volatile}`` —
  ``committed`` is the full append-only text so far and ``draft`` the short
  revisable tail after it (keystroke typing); ``finalized`` will never be
  re-transcribed and ``volatile`` is the latest reading of the current phrase
  (marked-text insertion).
- ``response.audio_transcript.done`` ``{text}`` — final text after commit.
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any

import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

from .local_agreement import LocalAgreementStreamer, TimedWord, Transcribe
from .realtime_audio import decode_pcm16_base64

logger = logging.getLogger("local_dictation_server.parakeet")

_MIN_PASS_SECONDS = 0.3


def tokens_to_words(tokens: Any) -> list[TimedWord]:
    """Group sentencepiece tokens (leading space = new word) into timed words."""
    words: list[TimedWord] = []
    text, start, end = "", 0.0, 0.0
    for token in tokens:
        piece = token.text
        if piece.startswith(" ") or not text:
            if text.strip():
                words.append(TimedWord(text.strip(), start, end))
            text, start = piece, float(token.start)
        else:
            text += piece
        end = float(token.end)
    if text.strip():
        words.append(TimedWord(text.strip(), start, end))
    return words


def make_parakeet_transcriber(model: Any) -> Transcribe:
    """Full-attention batch transcription → timed words (MLX, caller's thread)."""
    from parakeet_mlx.audio import get_logmel

    import mlx.core as mx  # ty: ignore[unresolved-import]  (native extension, no stubs)

    sample_rate = int(getattr(model.preprocessor_config, "sample_rate", 16_000))
    min_samples = int(sample_rate * _MIN_PASS_SECONDS)

    def transcribe(audio: np.ndarray) -> list[TimedWord]:
        if audio.size < min_samples:
            return []
        mel = get_logmel(mx.array(audio), model.preprocessor_config)
        result = model.generate(mel)[0]
        tokens = [t for sentence in result.sentences for t in sentence.tokens]
        return tokens_to_words(tokens)

    return transcribe


class ParakeetStreamSession:
    """One WebSocket's utterances over a shared parakeet-mlx model."""

    def __init__(self, transcribe: Transcribe, step_seconds: float = 0.5):
        self.transcribe = transcribe
        self.step_seconds = step_seconds
        self.streamer = self._new_streamer()

    def _new_streamer(self) -> LocalAgreementStreamer:
        return LocalAgreementStreamer(self.transcribe, step_seconds=self.step_seconds)

    def reset(self) -> None:
        self.streamer = self._new_streamer()

    def feed_audio(self, audio_f32: np.ndarray) -> dict[str, Any] | None:
        snapshot = self.streamer.add_audio(audio_f32)
        if snapshot is None:
            return None
        return {
            "type": "transcript.snapshot",
            "committed": snapshot.committed,
            "draft": snapshot.draft,
            "finalized": snapshot.finalized,
            "volatile": snapshot.volatile,
        }

    def finalize(self) -> list[dict[str, Any]]:
        started = time.monotonic()
        text = self.streamer.finalize()
        logger.info(
            "parakeet finalize audio=%.1fs chars=%d in %.0fms",
            self.streamer.duration,
            len(text),
            (time.monotonic() - started) * 1000,
        )
        self.reset()
        return [
            {
                "type": "transcript.snapshot",
                "committed": text,
                "draft": "",
                "finalized": text,
                "volatile": "",
            },
            {"type": "response.audio_transcript.done", "text": text},
        ]


def create_parakeet_app(model_id: str, chunk_seconds: float = 0.5):
    """Create FastAPI app that loads parakeet-mlx and speaks the realtime protocol."""
    try:
        from parakeet_mlx import from_pretrained
    except ImportError as exc:
        raise SystemExit(
            "parakeet-mlx is not installed. Run: "
            "cd server && uv sync --group parakeet --python 3.12"
        ) from exc

    logger.info("Loading parakeet-mlx model: %s", model_id)
    t0 = time.monotonic()
    model = from_pretrained(model_id)
    logger.info("parakeet-mlx loaded in %.1fs", time.monotonic() - t0)
    transcribe = make_parakeet_transcriber(model)
    # Warm the MLX graph so the first dictation pass is not a cold compile.
    transcribe(np.zeros(16_000, dtype=np.float32))
    step_seconds = min(1.5, max(0.4, float(chunk_seconds)))
    logger.info("parakeet-mlx pass step=%.2fs", step_seconds)

    app = FastAPI(title="local-dictation parakeet-mlx server")

    @app.get("/health")
    async def health() -> JSONResponse:
        return JSONResponse(
            {"status": "ok", "backend": "parakeet-mlx", "model": model_id}
        )

    @app.websocket("/v1/realtime")
    async def realtime(websocket: WebSocket) -> None:
        await websocket.accept()
        logger.info("WebSocket connected (parakeet-mlx)")
        session = ParakeetStreamSession(transcribe, step_seconds=step_seconds)
        await websocket.send_json({"type": "session.created"})

        try:
            while True:
                raw = await websocket.receive_text()
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    await websocket.send_json(
                        {"type": "error", "message": "Invalid JSON"}
                    )
                    continue

                msg_type = msg.get("type", "")

                if msg_type == "session.update":
                    await websocket.send_json({"type": "session.updated"})

                elif msg_type == "input_audio_buffer.append":
                    audio_b64 = msg.get("audio", "")
                    if not audio_b64:
                        continue
                    try:
                        audio_f32 = decode_pcm16_base64(audio_b64)
                    except ValueError:
                        await websocket.send_json(
                            {
                                "type": "error",
                                "message": "Invalid PCM16 payload length",
                            }
                        )
                        continue

                    # MLX must stay on this thread (no Stream in worker threads).
                    if event := session.feed_audio(audio_f32):
                        await websocket.send_json(event)

                elif msg_type == "input_audio_buffer.commit":
                    if msg.get("final", False):
                        for event in session.finalize():
                            await websocket.send_json(event)

                elif msg_type == "input_audio_buffer.clear":
                    session.reset()
                    await websocket.send_json({"type": "input_audio_buffer.cleared"})

        except WebSocketDisconnect:
            logger.info("WebSocket disconnected (parakeet-mlx)")
        except Exception:
            logger.exception("WebSocket error (parakeet-mlx)")

    return app
