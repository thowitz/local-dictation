"""Benchmark runner for Python engines (parakeet-mlx, moondream Photon).

Usage:
  run_py.py <name> mlx <model_dir>
  run_py.py <name> photon <hf_id> [device]

Writes results/<name>.json with batch hypotheses + timings and, for each
streaming session, the LocalAgreement snapshot sequence (replayed through the
Swift DictationTypist later), per-pass latency, and the final text.
"""

import json
import os
import sys
import time
import wave
from pathlib import Path

import numpy as np

ROOT = Path(
    os.environ.get("LD_BENCH_DIR", Path.home() / "Library/Caches/ld-bench/bench")
)
SERVER_SRC = str(Path(__file__).resolve().parents[1] / "server" / "src")
sys.path.insert(0, SERVER_SRC)
from local_dictation_server.local_agreement import (  # noqa: E402
    LocalAgreementStreamer,
    TimedWord,
)

name, kind, model = sys.argv[1] + os.environ.get("SUFFIX", ""), sys.argv[2], sys.argv[3]
device = sys.argv[4] if len(sys.argv) > 4 else "mps"
STEP = float(os.environ.get("STEP", "0.5"))


def load_wav(path):
    with wave.open(path) as w:
        return (
            np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32)
            / 32768.0
        )


t0 = time.monotonic()
if kind == "mlx":
    from local_dictation_server.parakeet_backend import make_parakeet_transcriber
    from parakeet_mlx import from_pretrained

    transcribe = make_parakeet_transcriber(from_pretrained(model))
    close = lambda: None  # noqa: E731
elif kind == "photon":
    import moondream as md

    ctx = md.photon(model, device=device)
    speech = ctx.__enter__()
    close = lambda: ctx.__exit__(None, None, None)  # noqa: E731

    def transcribe(audio):
        if audio.size < 4800:
            return []
        r = speech.transcribe(audio=audio, sample_rate=16000, timestamps="word")
        return [
            TimedWord(w["word"].strip(), float(w["start"]), float(w["end"]))
            for seg in r.get("segments", [])
            for w in seg.get("words", [])
            if w["word"].strip()
        ]
else:
    raise SystemExit(f"unknown kind {kind}")
load_s = time.monotonic() - t0
for _ in range(3):  # warm up graphs / kernels
    transcribe(
        np.zeros(16000 * 3, np.float32)
        + np.float32(0.01)
        * np.random.default_rng(0).standard_normal(48000).astype(np.float32)
    )

result = {
    "engine": name,
    "kind": kind,
    "model": model,
    "load_s": load_s,
    "step": STEP,
    "batch": [],
    "stream": [],
}

for item in json.load(open(ROOT / os.environ.get("BATCH", "batch.json"))):
    audio = load_wav(item["wav"])
    padded = np.concatenate([audio, np.zeros(8000, np.float32)])
    t = time.monotonic()
    words = transcribe(padded)
    ms = (time.monotonic() - t) * 1000
    result["batch"].append(
        {
            "id": item["id"],
            "hyp": " ".join(w.text for w in words),
            "audio_s": item["seconds"],
            "ms": ms,
        }
    )
print(f"{name}: batch done", flush=True)

for item in (
    []
    if os.environ.get("STREAM") == "none"
    else json.load(open(ROOT / os.environ.get("STREAM", "stream.json")))
):
    audio = load_wav(item["wav"])
    s = LocalAgreementStreamer(transcribe, step_seconds=STEP)
    snaps, pass_ms = [], []
    for i in range(0, audio.size, 1600):
        t = time.monotonic()
        snap = s.add_audio(audio[i : i + 1600])
        if s._samples_since_pass == 0:
            pass_ms.append((time.monotonic() - t) * 1000)
        if snap is not None:
            snaps.append([snap.committed, snap.draft])
    t = time.monotonic()
    final = s.finalize()
    final_ms = (time.monotonic() - t) * 1000
    result["stream"].append(
        {
            "id": item["id"],
            "audio_s": item["seconds"],
            "snapshots": snaps,
            "pass_ms": pass_ms,
            "final": final,
            "final_ms": final_ms,
        }
    )
    print(f"{name}: stream {item['id']} p50={np.median(pass_ms):.0f}ms", flush=True)

close()
(ROOT / "results").mkdir(exist_ok=True)
json.dump(result, open(ROOT / "results" / f"{name}.json", "w"))
print(f"{name}: wrote results (load {load_s:.1f}s)", flush=True)
