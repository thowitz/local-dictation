#!/usr/bin/env python3
"""Stream a 16 kHz mono PCM16 WAV over the OpenAI Realtime subset WebSocket.

Usage:
    uv run python scripts/ws_smoke.py [--port PORT] path/to/audio.wav
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import sys
import time
import wave
from pathlib import Path


async def run_smoke(wav_path: Path, host: str, port: int, chunk_ms: int) -> str:
    try:
        import websockets
    except ImportError as exc:
        raise SystemExit(
            "websockets is required (comes with uvicorn[standard])"
        ) from exc

    with wave.open(str(wav_path), "rb") as wf:
        if wf.getnchannels() != 1:
            raise SystemExit(f"expected mono WAV, got {wf.getnchannels()} channels")
        if wf.getsampwidth() != 2:
            raise SystemExit(f"expected 16-bit PCM, got sampwidth={wf.getsampwidth()}")
        if wf.getframerate() != 16000:
            raise SystemExit(f"expected 16 kHz, got {wf.getframerate()} Hz")
        pcm = wf.readframes(wf.getnframes())

    samples_per_chunk = max(1, int(16000 * (chunk_ms / 1000.0)))
    bytes_per_chunk = samples_per_chunk * 2  # int16

    uri = f"ws://{host}:{port}/v1/realtime"
    deltas: list[str] = []
    final_text = ""

    async with websockets.connect(uri, max_size=8 * 1024 * 1024) as ws:
        # session.created
        created = json.loads(await ws.recv())
        if created.get("type") != "session.created":
            raise SystemExit(f"unexpected first event: {created}")

        offset = 0
        while offset < len(pcm):
            chunk = pcm[offset : offset + bytes_per_chunk]
            offset += len(chunk)
            await ws.send(
                json.dumps(
                    {
                        "type": "input_audio_buffer.append",
                        "audio": base64.b64encode(chunk).decode("ascii"),
                    }
                )
            )
            # Drain any deltas that arrived while we paced
            while True:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=0.001)
                except asyncio.TimeoutError:
                    break
                msg = json.loads(raw)
                mtype = msg.get("type")
                if mtype == "response.audio_transcript.delta":
                    deltas.append(msg.get("delta", ""))
                elif mtype == "response.audio_transcript.done":
                    final_text = msg.get("text", "")
                elif mtype == "error":
                    raise SystemExit(f"server error: {msg}")
            # Real-time-ish pacing
            await asyncio.sleep(chunk_ms / 1000.0)

        await ws.send(json.dumps({"type": "input_audio_buffer.commit", "final": True}))

        # Collect remaining events until .done
        deadline = time.monotonic() + 120.0
        while not final_text and time.monotonic() < deadline:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=30.0)
            except asyncio.TimeoutError:
                break
            msg = json.loads(raw)
            mtype = msg.get("type")
            if mtype == "response.audio_transcript.delta":
                deltas.append(msg.get("delta", ""))
            elif mtype == "response.audio_transcript.done":
                final_text = msg.get("text", "")
            elif mtype == "error":
                raise SystemExit(f"server error: {msg}")

    assembled = "".join(deltas)
    transcript = final_text or assembled
    return transcript


def main() -> None:
    parser = argparse.ArgumentParser(
        description="WebSocket smoke test for local-dictation server"
    )
    parser.add_argument("wav", type=Path, help="16 kHz mono PCM16 WAV file")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8471)
    parser.add_argument(
        "--chunk-ms",
        type=int,
        default=80,
        help="Audio chunk size in milliseconds (default 80)",
    )
    args = parser.parse_args()

    if not args.wav.is_file():
        raise SystemExit(f"WAV not found: {args.wav}")

    transcript = asyncio.run(run_smoke(args.wav, args.host, args.port, args.chunk_ms))
    print(transcript)
    if not transcript.strip():
        print("FAIL: empty transcript", file=sys.stderr)
        raise SystemExit(1)
    raise SystemExit(0)


if __name__ == "__main__":
    main()
