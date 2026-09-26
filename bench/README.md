# ASR benchmarks

How the speech engines Local Dictation can use compare on accuracy, speed,
noise and German, measured through the app's real streaming path
(`LocalAgreementStreamer` → `DictationTypist`). Results from 2026-09-26 are in
[`results/2026-09-26/`](results/2026-09-26/).

## Recommendation

**Parakeet Ultra** (Moondream's post-trained Parakeet TDT v3), on MLX or CoreML:

- In babble noise (8 other talkers) it makes 25–30% fewer errors than v2/v3.
- On German it makes ~14% fewer errors than v3.
- It keeps v3's 25 languages.
- In quiet English, v2 is marginally more accurate (English only).

Everything below comes from the committed result files; `score.py` reproduces
each table.

## Method

- **Batch:** 200 random utterances each from LibriSpeech test-clean and test-other (seed 0, `prep.py`).
- **Streaming:** 16 "dictation sessions" of 45–80 s each (14 min total). Each is stitched from consecutive utterances of one chapter, with 0.35 s pauses. Audio is fed in 100 ms chunks through `LocalAgreementStreamer` (0.5 s step), and every snapshot is replayed through the Swift `DictationTypist` (`BenchmarkTests.replayTypist`).
- **Noise** (`prep_noise.py`): 150 of the batch utterances mixed with 8-talker babble from other LibriSpeech speakers, never the target speaker, at 10 / 5 / 0 dB SNR. At 0 dB the chatter is as loud as the speaker.
- **German:** 166 unique sentences from FLEURS `de_de` test, scored with Whisper's language-neutral normaliser.
- **Long:** the 25 batch utterances longer than 15 s, used to check FluidAudio's 15 s encoder window.
- **WER:** word error rate, using Whisper's English normaliser, so casing, punctuation and "10"/"ten" don't count.
- **RTFx:** audio seconds divided by processing seconds.
- **Hardware:** Mac mini M1 (8-core GPU, 16 GB) for everything, plus a speed check on a MacBook Pro M1 Max (subset of 100 utterances + 4 sessions). Speed on the mini's base M1 GPU is about 4× slower than the M1 Max, and an iOS simulator was running on it, so compare speeds within one machine only. Accuracy doesn't depend on hardware.

Engines:

| Prefix | Runtime |
|---|---|
| `mlx-` | parakeet-mlx on the GPU (the server backend) |
| `coreml-` | FluidAudio 0.17.4 on the Neural Engine (in-process) |
| `apple-speech` | macOS 26 SpeechTranscriber (new model) |
| `apple-dictation` | macOS 26 DictationTranscriber (system Dictation's model) |

Models:

| Name | Model |
|---|---|
| v2 | `nvidia/parakeet-tdt-0.6b-v2` (English) |
| v3 | `nvidia/parakeet-tdt-0.6b-v3` (25 languages) |
| 1.1b | `nvidia/parakeet-tdt-1.1b` (English) |
| ultra | `moondream/parakeet-ultra` (v3 post-trained). MLX: `selcukkubur/parakeet-ultra-mlx`; CoreML: `FluidInference/parakeet-ultra-coreml` |
| redux | `moondream/parakeet-redux` (ternary v3). CoreML: `FluidInference/parakeet-redux-coreml` |

## Results (Mac mini M1)

In the tables below, "Largest correction" is the largest single backspace run while typing.

| Engine | Clean | Other | Streaming (typed) | Batch RTFx | Pass p50 / p95 | Largest correction | Typed = final |
|---|---|---|---|---|---|---|---|
| mlx-v2 | 2.12 | 3.25 | **2.83** | 17 | 460 / 798 ms | 96 | 16/16 |
| mlx-v3 | 2.54 | 4.29 | 3.54 | 16 | 497 / 848 ms | 89 | 16/16 |
| mlx-ultra | 2.43 | 3.96 | 3.58 | 15 | 504 / 876 ms | 67 | 16/16 |
| mlx-1.1b | **1.96** | **2.92** | 2.79 | 13 | 850 / 1596 ms | 35 | 16/16 |
| coreml-v2 | 2.33 | 3.22 | 3.23 | **68** | **113 / 169 ms** | 62 | 16/16 |
| coreml-v3 | 2.78 | 4.27 | 3.63 | 37 | 161 / 376 ms | 68 | 16/16 |
| coreml-ultra | 2.51 | 3.88 | 3.63 | 51 | 149 / 354 ms | 65 | 16/16 |
| coreml-redux | 2.93 | 5.37 | 3.63 | 37 | 197 / 450 ms | 75 | 16/16 |
| apple-speech | 2.04 | 4.49 | 2.48\* | 28 | — | — | — |
| apple-dictation | 8.57 | 15.85 | 9.47\* | 17 | — | — | — |

\* Apple's own finalized text, not typed through our typist.

**Parakeet 1.1B outputs no punctuation or capitals (0 of 400 utterances)**,
so it's unusable for dictation despite its WER.

### Background babble (8 talkers)

| Engine | 10 dB | 5 dB | 0 dB | Same 150 utterances, no noise |
|---|---|---|---|---|
| **mlx-ultra** | **4.48** | **11.68** | **38.97** | 2.66 |
| **coreml-ultra** | **4.51** | 12.12 | 39.30 | 2.73 |
| mlx-v2 | 5.64 | 15.83 | 51.75 | 2.44 |
| mlx-v3 | 6.11 | 15.94 | 50.98 | 3.02 |
| coreml-v2 | 6.15 | 18.30 | 56.88 | 2.77 |
| coreml-v3 | 6.51 | 18.27 | 53.60 | 3.31 |
| apple-speech | 10.26 | 25.44 | 63.72 | 2.51 |

### German (FLEURS de_de)

| Engine | WER |
|---|---|
| **mlx-ultra** | **6.01** |
| coreml-ultra | 6.53 |
| mlx-v3 | 7.00 |
| coreml-v3 | 7.41 |

### FluidAudio long-audio bug

FluidAudio 0.15.5 silently dropped everything after the first 15 s window of
v3 audio: 1,155 of 1,268 words came back, for 11.4% / 12.4% WER on clips over
15 s. A fresh v3 model download behaved identically, so it wasn't the model
files. FluidAudio 0.17.4 fixes it (`coreml-v3-long-fa174`: 3.25% / 3.54%). The
app now requires 0.17.4, and every CoreML number above uses it.

## MacBook Pro M1 Max (speed check, 100 utterances + 4 sessions)

| Engine | Clean | Other | Streaming | Batch RTFx | Pass p50 / p95 |
|---|---|---|---|---|---|
| mlx-v3 | 1.58 | 3.04 | 3.63 | **64** | **128 / 243 ms** |
| coreml-ultra | 1.48 | 3.16 | 3.14 | 44 | 173 / 267 ms |
| coreml-redux | 2.22 | 4.06 | 3.30 | 31 | 221 / 344 ms |
| coreml-v3† | 3.06 | 3.83 | 4.95 | 43 | 162 / 262 ms |

† Run on FluidAudio 0.15.5, so it's affected by the long-audio bug.

On an M1 Max, MLX is the fastest engine. A live pass takes ~0.13 s per 0.5 s
step, so the machine is busy roughly a quarter of real time.

## Apple's live revision behaviour

The streaming probe (`BenchmarkTests.apple`, analysed by `analyze_apple.py`)
feeds audio at 2× real time and logs every volatile and final result.

With SpeechTranscriber:
- A phrase stays volatile for p50 7.7 s of audio (max 31 s).
- A revision deletes a median of 15 words (max 77).
- A revision reaches back a median of ~16 s.

So Apple revises whole phrases. That's safe for Apple because it edits through
marked text, which is also how Local Dictation's input method works now.

## Not included

Moondream's Photon runtime (Redux/Ultra) was measured, at roughly 1.75×
parakeet-mlx's batch speed on the M1 GPU. Its results aren't committed:
Photon's kernels ship under a proprietary licence that requires a separate
written agreement.

## Reproduce

```bash
export LD_BENCH_DIR=~/Library/Caches/ld-bench/bench   # manifests, audio and results live here
python bench/prep.py && python bench/prep_noise.py      # needs LibriSpeech parquet in $LD_BENCH_DIR/../data
python bench/run_py.py mlx-v3 mlx <mlx model dir>        # server venv (parakeet-mlx)
LD_BENCH_DIR=$LD_BENCH_DIR LD_BENCH_COREML="coreml-v3=<dir>:v3" \
  swift test --filter BenchmarkTests                     # CoreML (+ LD_BENCH_APPLE=1, LD_BENCH_REPLAY=1)
python bench/score.py $LD_BENCH_DIR/results $LD_BENCH_DIR
```

`BATCH`/`STREAM`/`SUFFIX` (Python) and `LD_BENCH_BATCH`/`LD_BENCH_STREAM`/`LD_BENCH_SUFFIX`
(Swift) select the noise, German and long manifests. Test audio comes from
LibriSpeech and FLEURS (CC BY 4.0).
