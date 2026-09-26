"""How far back does Apple's on-device transcriber revise shown text?

For each streaming session, rebuild the text an app would display after every
result (finalized phrases in order + the newest volatile phrase after them) and
measure each update's revision depth: characters/words that would need to be
backspaced, and how many seconds of audio behind "now" the revision starts.
"""

import json
import os
from pathlib import Path

import numpy as np

ROOT = Path(
    os.environ.get("LD_BENCH_DIR", Path.home() / "Library/Caches/ld-bench/bench")
)


def cp(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


for name in ("apple-speech", "apple-dictation"):
    path = ROOT / "results" / f"{name}.json"
    if not path.exists():
        continue
    r = json.load(open(path))
    depth_chars, depth_words, reach_s, volatile_len_s, final_lag = [], [], [], [], []
    for sess in r["stream"]:
        finals = []  # (start, end, text)
        volatile = None
        shown = ""
        first_seen = {}
        for ev in sess["apple_events"]:
            key = round(ev["start"], 2)
            if ev["final"]:
                finals.append((ev["start"], ev["end"], ev["text"]))
                finals.sort()
                volatile = None
                if key in first_seen:
                    final_lag.append(ev["wall"] - first_seen[key])
            else:
                volatile = (ev["start"], ev["end"], ev["text"])
                first_seen.setdefault(key, ev["wall"])
                volatile_len_s.append(ev["end"] - ev["start"])
            text = " ".join(t.strip() for _, _, t in finals if t.strip())
            if volatile and (not finals or volatile[0] >= finals[-1][1] - 0.05):
                text = (text + " " + volatile[2].strip()).strip()
            shared = cp(shown, text)
            deleted = len(shown) - shared
            if deleted > 0:
                depth_chars.append(deleted)
                depth_words.append(len(shown[shared:].split()))
                # audio time where the revised text started ≈ start of the phrase containing it
                reach_s.append(
                    max(
                        0.0,
                        (ev["wall"] * 2) - (volatile[0] if volatile else ev["start"]),
                    )
                )
            shown = text

    def stats(xs, fmt="{:.1f}"):
        if not xs:
            return "n/a"
        return f"p50={fmt.format(np.median(xs))} p90={fmt.format(np.percentile(xs, 90))} max={fmt.format(max(xs))}"

    print(
        f"== {name}: {sum(len(s['apple_events']) for s in r['stream'])} results over {len(r['stream'])} sessions"
    )
    print(f"   revisions that delete shown text: {len(depth_chars)}")
    print(f"   chars deleted per revision:  {stats(depth_chars, '{:.0f}')}")
    print(f"   words deleted per revision:  {stats(depth_words, '{:.0f}')}")
    print(f"   revision reaches back (audio s): {stats(reach_s)}")
    print(f"   volatile phrase length (audio s): {stats(volatile_len_s)}")
    print(f"   wall time phrase volatile→final (s, at 2x feed): {stats(final_lag)}")
