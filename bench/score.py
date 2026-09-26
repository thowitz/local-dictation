"""Score benchmark results with one normalizer.

Usage: score.py <results_dir> <manifest_dir> [--json out.json]

WER uses Whisper's English normalizer, so "10" vs "ten", casing and
punctuation don't count. Batch items are grouped by the split prefix of their
id (clean / other / snr10 / snr5 / snr0). Streaming metrics come from the Swift
DictationTypist replay (`*.typed.json`).
"""

import gzip
import json
import sys
from pathlib import Path

import numpy as np
from whisper_normalizer.basic import BasicTextNormalizer
from whisper_normalizer.english import EnglishTextNormalizer

ENGLISH = EnglishTextNormalizer()
# Non-English splits (e.g. FLEURS German) use Whisper's language-neutral normalizer.
BASIC = BasicTextNormalizer()


def load(path: Path):
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt") as f:
        return json.load(f)


def edits(h, r):
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev = cur
    return d[len(h)]


def wer(pairs, norm=ENGLISH):
    e = n = 0
    for hyp, ref in pairs:
        h, r = norm(hyp).split(), norm(ref).split()
        e += edits(h, r)
        n += len(r)
    return 100 * e / max(1, n)


def main():
    results, manifests = Path(sys.argv[1]), Path(sys.argv[2])
    refs = {}
    for m in manifests.glob("*.json*"):
        items = load(m)
        if isinstance(items, list):
            refs.update({i["id"]: i["ref"] for i in items if isinstance(i, dict) and "ref" in i})

    rows = []
    for path in sorted(results.glob("*.json*")):
        if ".typed." in path.name:
            continue
        stem = path.name.split(".json")[0]
        typed = [p for p in results.glob(f"{stem}.typed.json*")]
        r = load(typed[0] if typed else path)
        row = {"engine": r["engine"], "load_s": round(r.get("load_s", 0), 1)}
        b = r.get("batch", [])
        for split in sorted({x["id"].split("-")[0] for x in b}):
            pairs = [(x["hyp"], refs[x["id"]]) for x in b if x["id"].startswith(split + "-")]
            row[f"wer_{split}"] = round(wer(pairs, BASIC if split == "de" else ENGLISH), 2)
        if b:
            row["rtfx"] = round(sum(x["audio_s"] for x in b) / (sum(x["ms"] for x in b) / 1000), 1)
        s = r.get("stream", [])
        if s:
            row["wer_stream_final"] = round(wer([(x["final"], refs[x["id"]]) for x in s]), 2)
            if "typed" in s[0]:
                row["wer_stream_typed"] = round(wer([(x["typed"], refs[x["id"]]) for x in s]), 2)
                row["max_del"] = max(x["max_del"] for x in s)
                row["del_per_min"] = round(sum(x["total_del"] for x in s) / (sum(x["audio_s"] for x in s) / 60))
                row["realigns"] = sum(x["realigns"] for x in s)
                row["typed_eq_final"] = f"{sum(x['typed'] == x['final'] for x in s)}/{len(s)}"
            passes = [m for x in s for m in x.get("pass_ms", [])]
            if passes:
                row["pass_p50_ms"] = round(float(np.median(passes)))
                row["pass_p95_ms"] = round(float(np.percentile(passes, 95)))
        rows.append(row)

    cols = sorted({k for row in rows for k in row} - {"engine"})
    cols = ["engine"] + [c for c in cols if c.startswith("wer_")] + [c for c in cols if not c.startswith("wer_")]
    print("| " + " | ".join(cols) + " |")
    print("|" + "---|" * len(cols))
    for row in rows:
        print("| " + " | ".join(str(row.get(c, "")) for c in cols) + " |")
    if "--json" in sys.argv:
        json.dump(rows, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
