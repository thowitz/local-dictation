"""Noisy + long-utterance sets.

noise.json: 150 of the batch utterances (75 clean + 75 other) mixed with
8-talker babble (other LibriSpeech speakers, never the target speaker) at
10, 5 and 0 dB SNR — a stand-in for dictating on a bus full of friends.
long.json: every batch utterance longer than 15 s (FluidAudio window test).
"""

import io
import json
import os
import random
import wave
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf

root = Path(
    os.environ.get("LD_BENCH_DIR", Path.home() / "Library/Caches/ld-bench/bench")
)
batch = json.load(open(root / "batch.json"))
json.dump(
    [b for b in batch if b["seconds"] >= 15], open(root / "long.json", "w"), indent=1
)

pool = []
used = {b["id"].split("-", 1)[1] for b in batch}
for split in ["test.clean", "test.other"]:
    for r in pq.read_table(
        Path(os.environ.get("LD_LIBRISPEECH_DIR", root.parent / "data"))
        / "all"
        / split
        / "0000.parquet"
    ).to_pylist():
        if r["id"] in used:
            continue
        a, _ = sf.read(io.BytesIO(r["audio"]["bytes"]), dtype="float32")
        pool.append((r["speaker_id"], a / (np.sqrt(np.mean(a**2)) + 1e-9)))

rng = random.Random(1)
targets = [b for b in batch if b["split"] == "clean"][:75] + [
    b for b in batch if b["split"] == "other"
][:75]
out = []
for snr in (10, 5, 0):
    d = root / "noise" / f"snr{snr}"
    d.mkdir(parents=True, exist_ok=True)
    for b in targets:
        with wave.open(b["wav"]) as w:
            speech = (
                np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(
                    np.float32
                )
                / 32768
            )
        speaker = b["id"].split("-")[1]
        babble = np.zeros_like(speech)
        talkers = rng.sample([p for p in pool if str(p[0]) != speaker], 8)
        for _, t in talkers:
            reps = int(np.ceil(speech.size / t.size)) + 1
            loop = np.tile(t, reps)
            start = rng.randrange(0, t.size)
            babble += loop[start : start + speech.size]
        s_rms = np.sqrt(np.mean(speech**2))
        n_rms = np.sqrt(np.mean(babble**2))
        mix = speech + babble * (s_rms / n_rms) / (10 ** (snr / 20))
        mix *= 0.9 / max(1e-9, np.max(np.abs(mix)))
        p = d / f"{b['id']}.wav"
        with wave.open(str(p), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(np.clip(mix * 32767, -32768, 32767).astype("<i2").tobytes())
        out.append(
            dict(
                id=f"snr{snr}-{b['id']}",
                wav=str(p),
                ref=b["ref"],
                seconds=b["seconds"],
                split=f"snr{snr}",
            )
        )
json.dump(out, open(root / "noise.json", "w"), indent=1)
print(
    len(out),
    "noisy utterances;",
    len(json.load(open(root / "long.json"))),
    "long utterances",
)
