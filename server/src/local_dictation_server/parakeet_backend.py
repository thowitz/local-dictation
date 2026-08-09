"""Parakeet MLX realtime backend (OpenAI Realtime subset).

Uses parakeet-mlx streaming so partial transcripts arrive while audio is
buffered. Protocol matches the Voxtral path in server.py.
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any

import numpy as np

from .realtime_audio import decode_pcm16_base64

logger = logging.getLogger("local_dictation_server.parakeet")


class ParakeetStreamSession:
    """One WebSocket utterance over a shared parakeet-mlx model."""

    def __init__(self, model: Any, chunk_seconds: float = 1.0):
        self.model = model
        self.chunk_seconds = max(0.25, float(chunk_seconds))
        self.sample_rate = int(getattr(model.preprocessor_config, "sample_rate", 16_000))
        self.chunk_samples = int(self.sample_rate * self.chunk_seconds)
        self._reset_stream()

    def _reset_stream(self) -> None:
        self.stream_cm = self.model.transcribe_stream(context_size=(256, 256))
        self.transcriber = self.stream_cm.__enter__()
        self.pending = np.zeros(0, dtype=np.float32)
        self.emitted_text = ""
        self.full_text = ""

    def reset(self) -> None:
        try:
            self.stream_cm.__exit__(None, None, None)
        except Exception:
            logger.exception("parakeet stream close failed")
        self._reset_stream()

    def close(self) -> None:
        try:
            self.stream_cm.__exit__(None, None, None)
        except Exception:
            logger.exception("parakeet stream close failed")

    def _incremental_delta(self, full: str) -> str:
        if not self.emitted_text:
            return full
        if full.startswith(self.emitted_text):
            return full[len(self.emitted_text) :]
        return ""

    def feed_audio(self, audio_f32: np.ndarray) -> list[str]:
        """Append PCM float32 mono; return new text deltas (0 or 1 item)."""
        if audio_f32.size == 0:
            return []
        if audio_f32.dtype != np.float32:
            audio_f32 = audio_f32.astype(np.float32, copy=False)

        self.pending = (
            np.concatenate([self.pending, audio_f32]) if self.pending.size else audio_f32
        )
        deltas: list[str] = []
        while self.pending.size >= self.chunk_samples:
            chunk = self.pending[: self.chunk_samples]
            self.pending = self.pending[self.chunk_samples :]
            self.transcriber.add_audio(chunk)
            full = (self.transcriber.result.text or "").strip()
            self.full_text = full
            delta = self._incremental_delta(full)
            if delta:
                self.emitted_text += delta
                deltas.append(delta)
        return deltas

    def finalize(self) -> list[str]:
        """Flush remaining audio and return remaining deltas."""
        deltas: list[str] = []
        if self.pending.size:
            self.transcriber.add_audio(self.pending)
            self.pending = np.zeros(0, dtype=np.float32)
            full = (self.transcriber.result.text or "").strip()
            self.full_text = full
            delta = self._incremental_delta(full)
            if delta:
                self.emitted_text += delta
                deltas.append(delta)
        if not self.full_text and self.emitted_text:
            self.full_text = self.emitted_text
        return deltas


def create_parakeet_app(model_id: str, chunk_seconds: float = 1.0):
    """Create FastAPI app that loads parakeet-mlx and speaks the realtime protocol."""
    from fastapi import FastAPI, WebSocket, WebSocketDisconnect
    from fastapi.responses import JSONResponse

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

    app = FastAPI(title="local-dictation parakeet-mlx server")

    @app.get("/health")
    async def health():
        return JSONResponse({"status": "ok", "backend": "parakeet-mlx", "model": model_id})

    @app.websocket("/v1/realtime")
    async def realtime(ws: WebSocket):
        await ws.accept()
        logger.info("WebSocket connected (parakeet-mlx)")
        session = ParakeetStreamSession(model, chunk_seconds=chunk_seconds)
        await ws.send_json({"type": "session.created"})

        try:
            while True:
                raw = await ws.receive_text()
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    await ws.send_json({"type": "error", "message": "Invalid JSON"})
                    continue

                msg_type = msg.get("type", "")

                if msg_type == "session.update":
                    await ws.send_json({"type": "session.updated"})

                elif msg_type == "input_audio_buffer.append":
                    audio_b64 = msg.get("audio", "")
                    if not audio_b64:
                        continue
                    try:
                        audio_f32 = decode_pcm16_base64(audio_b64)
                    except ValueError:
                        await ws.send_json(
                            {
                                "type": "error",
                                "message": "Invalid PCM16 payload length",
                            }
                        )
                        continue

                    for tok in session.feed_audio(audio_f32):
                        await ws.send_json(
                            {
                                "type": "response.audio_transcript.delta",
                                "delta": tok,
                            }
                        )

                elif msg_type == "input_audio_buffer.commit":
                    is_final = msg.get("final", False)
                    if is_final:
                        for tok in session.finalize():
                            await ws.send_json(
                                {
                                    "type": "response.audio_transcript.delta",
                                    "delta": tok,
                                }
                            )
                        await ws.send_json(
                            {
                                "type": "response.audio_transcript.done",
                                "text": session.full_text or session.emitted_text,
                            }
                        )
                        session.reset()

                elif msg_type == "input_audio_buffer.clear":
                    session.reset()
                    await ws.send_json({"type": "input_audio_buffer.cleared"})

        except WebSocketDisconnect:
            logger.info("WebSocket disconnected (parakeet-mlx)")
        except Exception:
            logger.exception("WebSocket error (parakeet-mlx)")
        finally:
            session.close()

    return app
