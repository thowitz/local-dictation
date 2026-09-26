"""Build the benchmark set from LibriSpeech parquet: batch utterances + long streaming sessions."""

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
out_b, out_s = root / "batch", root / "stream"
out_b.mkdir(exist_ok=True)
out_s.mkdir(exist_ok=True)


def write_wav(path, audio):
    pcm = np.clip(audio * 32767, -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(pcm.tobytes())


batch, stream = [], []
for split in ["test.clean", "test.other"]:
    t = pq.read_table(
        Path(os.environ.get("LD_LIBRISPEECH_DIR", root.parent / "data"))
        / "all"
        / split
        / "0000.parquet"
    ).to_pylist()
    rows = []
    for r in t:
        audio, sr = sf.read(io.BytesIO(r["audio"]["bytes"]), dtype="float32")
        assert sr == 16000
        rows.append(
            dict(
                id=r["id"],
                speaker=r["speaker_id"],
                chapter=r["chapter_id"],
                text=r["text"],
                audio=audio,
            )
        )
    tag = split.split(".")[1]
    rng = random.Random(0)
    for r in rng.sample(rows, 200):
        p = out_b / f"{tag}-{r['id']}.wav"
        write_wav(p, r["audio"])
        batch.append(
            dict(
                id=p.stem,
                wav=str(p),
                ref=r["text"],
                seconds=len(r["audio"]) / 16000,
                split=tag,
            )
        )
    # Streaming sessions: consecutive utterances of one chapter, 45-75 s, 0.35 s pauses.
    by_ch = {}
    for r in sorted(rows, key=lambda r: r["id"]):
        by_ch.setdefault(r["chapter"], []).append(r)
    chapters = sorted(by_ch)
    rng.shuffle(chapters)
    made = 0
    for ch in chapters:
        parts, secs = [], 0.0
        for r in by_ch[ch]:
            parts.append(r)
            secs += len(r["audio"]) / 16000 + 0.35
            if secs >= 45:
                break
        if secs < 45 or secs > 80:
            continue
        gap = np.zeros(int(0.35 * 16000), np.float32)
        audio = np.concatenate([np.concatenate([p["audio"], gap]) for p in parts])
        p = out_s / f"{tag}-ch{ch}.wav"
        write_wav(p, audio)
        stream.append(
            dict(
                id=p.stem,
                wav=str(p),
                ref=" ".join(x["text"] for x in parts),
                seconds=len(audio) / 16000,
                split=tag,
            )
        )
        made += 1
        if made == 8:
            break
json.dump(batch, open(root / "batch.json", "w"), indent=1)
json.dump(stream, open(root / "stream.json", "w"), indent=1)
print(
    f"batch {len(batch)} utts {sum(b['seconds'] for b in batch) / 60:.1f} min; stream {len(stream)} sessions {sum(s['seconds'] for s in stream) / 60:.1f} min"
)
