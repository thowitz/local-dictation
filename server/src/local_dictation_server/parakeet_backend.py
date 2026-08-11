"""Parakeet MLX realtime backend (OpenAI Realtime subset).

Uses parakeet-mlx streaming so partial transcripts arrive while audio is
buffered. Partials are sent as *absolute* draft snapshots (volatile ASR drafts
revise freely). On commit, a non-streaming generate produces the final text.

Protocol matches the Voxtral path in server.py, with an extra ``absolute``
flag on delta events so the client can revise typed text live.
"""

from __future__ import annotations

import json
import logging
import re
import time
from dataclasses import dataclass
from typing import Any

import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

from .realtime_audio import decode_pcm16_base64

logger = logging.getLogger("local_dictation_server.parakeet")

_DEFAULT_CONTEXT_SIZE = (256, 256)
_MIN_PARTIAL_SECONDS = 0.35
_SILENCE_PEAK = 0.012
_SILENCE_RMS = 0.004
_FINAL_PAD_SECONDS = 0.35
_FILLER_ONLY = re.compile(
    r"^(yeah|yes|yep|yup|mm+|mhm+|uh+|um+|hmm+|ah+|oh+|mm-hmm)[.!?,\s]*$",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class TranscriptEvent:
    """One transcript update for the client."""

    text: str
    absolute: bool  # True → full draft so far; False → append-only suffix


class ParakeetStreamSession:
    """One WebSocket utterance over a shared parakeet-mlx model."""

    def __init__(self, model: Any, chunk_seconds: float = 0.5):
        self.model = model
        self.chunk_seconds = max(0.2, float(chunk_seconds))
        self.sample_rate = int(getattr(model.preprocessor_config, "sample_rate", 16_000))
        self.chunk_samples = int(self.sample_rate * self.chunk_seconds)
        self.min_partial_samples = int(self.sample_rate * _MIN_PARTIAL_SECONDS)
        self._reset_stream()

    def _reset_stream(self) -> None:
        self.stream_cm = self.model.transcribe_stream(context_size=_DEFAULT_CONTEXT_SIZE)
        self.transcriber = self.stream_cm.__enter__()
        self.pending = np.zeros(0, dtype=np.float32)
        self.utterance = np.zeros(0, dtype=np.float32)
        self.emitted_text = ""
        self.full_text = ""
        self._samples_fed = 0

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

    def _to_mx(self, chunk: np.ndarray) -> Any:
        try:
            import mlx.core as mx

            return mx.array(chunk)
        except ImportError:
            return chunk

    def _maybe_partial(self, full: str) -> TranscriptEvent | None:
        """Publish an absolute draft snapshot when the stream text changes."""
        full = (full or "").strip()
        self.full_text = full
        if self._samples_fed < self.min_partial_samples:
            return None
        if not full or full == self.emitted_text:
            return None
        if not self.emitted_text and _FILLER_ONLY.match(full):
            return None
        self.emitted_text = full
        return TranscriptEvent(text=full, absolute=True)

    def _push_chunk(self, chunk: np.ndarray, *, allow_partial: bool = True) -> TranscriptEvent | None:
        self.transcriber.add_audio(self._to_mx(chunk))
        self._samples_fed += int(chunk.size)
        full = (self.transcriber.result.text or "").strip()
        self.full_text = full
        if not allow_partial:
            return None
        return self._maybe_partial(full)

    def feed_audio(self, audio_f32: np.ndarray) -> list[TranscriptEvent]:
        if audio_f32.size == 0:
            return []
        if audio_f32.dtype != np.float32:
            audio_f32 = audio_f32.astype(np.float32, copy=False)
        audio_f32 = np.ascontiguousarray(audio_f32).reshape(-1)

        self.utterance = (
            np.concatenate([self.utterance, audio_f32])
            if self.utterance.size
            else audio_f32.copy()
        )
        self.pending = (
            np.concatenate([self.pending, audio_f32]) if self.pending.size else audio_f32
        )
        events: list[TranscriptEvent] = []
        while self.pending.size >= self.chunk_samples:
            chunk = self.pending[: self.chunk_samples]
            self.pending = self.pending[self.chunk_samples :]
            if ev := self._push_chunk(chunk):
                events.append(ev)
        return events

    def _is_silence(self, audio: np.ndarray) -> bool:
        if audio.size == 0:
            return True
        peak = float(np.max(np.abs(audio)))
        rms = float(np.sqrt(np.mean(np.square(audio), dtype=np.float64)))
        return peak < _SILENCE_PEAK and rms < _SILENCE_RMS

    def _batch_transcribe(self, audio: np.ndarray) -> str:
        if audio.size == 0 or self._is_silence(audio):
            return ""
        try:
            from parakeet_mlx.audio import get_logmel

            mel = get_logmel(self._to_mx(audio), self.model.preprocessor_config)
            result = self.model.generate(mel)[0]
            return (getattr(result, "text", None) or "").strip()
        except Exception:
            logger.exception("parakeet batch generate failed; falling back to stream text")
            return (self.full_text or self.emitted_text or "").strip()

    def finalize(self) -> list[TranscriptEvent]:
        events: list[TranscriptEvent] = []
        if self.pending.size:
            if ev := self._push_chunk(self.pending, allow_partial=True):
                events.append(ev)
            self.pending = np.zeros(0, dtype=np.float32)

        pad_n = int(self.sample_rate * _FINAL_PAD_SECONDS)
        if pad_n > 0 and self.utterance.size > 0:
            try:
                self._push_chunk(np.zeros(pad_n, dtype=np.float32), allow_partial=False)
            except Exception:
                logger.exception("parakeet final pad failed")

        batch = self._batch_transcribe(self.utterance)
        stream_full = (self.full_text or "").strip()
        if batch:
            self.full_text = batch
        elif stream_full and not self._is_silence(self.utterance):
            self.full_text = stream_full
        else:
            self.full_text = ""

        if self.full_text and self.full_text != self.emitted_text:
            events.append(TranscriptEvent(text=self.full_text, absolute=True))
            self.emitted_text = self.full_text
        return events


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

    app = FastAPI(title="local-dictation parakeet-mlx server")

    @app.get("/health")
    async def health() -> JSONResponse:
        return JSONResponse({"status": "ok", "backend": "parakeet-mlx", "model": model_id})

    @app.websocket("/v1/realtime")
    async def realtime(websocket: WebSocket) -> None:
        await websocket.accept()
        logger.info("WebSocket connected (parakeet-mlx)")
        session = ParakeetStreamSession(model, chunk_seconds=chunk_seconds)
        await websocket.send_json({"type": "session.created"})

        try:
            while True:
                raw = await websocket.receive_text()
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    await websocket.send_json({"type": "error", "message": "Invalid JSON"})
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
                    for ev in session.feed_audio(audio_f32):
                        payload: dict[str, Any] = {
                            "type": "response.audio_transcript.delta",
                            "delta": ev.text,
                        }
                        if ev.absolute:
                            payload["absolute"] = True
                        await websocket.send_json(payload)

                elif msg_type == "input_audio_buffer.commit":
                    is_final = msg.get("final", False)
                    if is_final:
                        for ev in session.finalize():
                            payload = {
                                "type": "response.audio_transcript.delta",
                                "delta": ev.text,
                            }
                            if ev.absolute:
                                payload["absolute"] = True
                            await websocket.send_json(payload)
                        await websocket.send_json(
                            {
                                "type": "response.audio_transcript.done",
                                "text": session.full_text or session.emitted_text,
                            }
                        )
                        session.reset()

                elif msg_type == "input_audio_buffer.clear":
                    session.reset()
                    await websocket.send_json({"type": "input_audio_buffer.cleared"})

        except WebSocketDisconnect:
            logger.info("WebSocket disconnected (parakeet-mlx)")
        except Exception:
            logger.exception("WebSocket error (parakeet-mlx)")
        finally:
            session.close()

    return app
