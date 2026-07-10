#!/usr/bin/env python3
"""Synthesize a 16 kHz mono PCM16 WAV via macOS `say` + `afconvert`.

Usage:
    uv run python scripts/make_test_wav.py [output.wav] [--text "..."]
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate a test WAV with macOS say")
    parser.add_argument(
        "output",
        nargs="?",
        type=Path,
        default=Path("test.wav"),
        help="Output WAV path (default: test.wav)",
    )
    parser.add_argument(
        "--text",
        default="Hello, this is a local dictation smoke test.",
        help="Text for macOS say to speak",
    )
    args = parser.parse_args()

    if not shutil.which("say"):
        raise SystemExit("macOS `say` command not found")
    if not shutil.which("afconvert"):
        raise SystemExit("macOS `afconvert` command not found")

    args.output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        aiff_path = Path(tmp) / "speech.aiff"
        # say -o writes AIFF by default; afconvert → 16 kHz mono LEI16 WAV
        subprocess.run(
            ["say", "-o", str(aiff_path), args.text],
            check=True,
        )
        subprocess.run(
            [
                "afconvert",
                str(aiff_path),
                str(args.output),
                "-f",
                "WAVE",
                "-d",
                "LEI16@16000",
                "-c",
                "1",
            ],
            check=True,
        )

    print(f"Wrote {args.output.resolve()}", file=sys.stderr)


if __name__ == "__main__":
    main()
