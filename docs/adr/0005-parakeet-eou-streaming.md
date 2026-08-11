# Parakeet CoreML uses TDT sliding-window partials (not EOU)

## Status

Accepted (supersedes the short-lived EOU experiment, 2026-08-10)

## Context

Parakeet TDT 0.6B v3 CoreML is a **batch / sliding-window** encoder. Live partials for the 0.6B model are done with FluidAudio `SlidingWindowAsrManager`: overlapping windows with left/center/right context, volatile then confirmed text.

FluidAudio’s long-form defaults use ~11 s centers (first update after ~13 s). Dictation needs a **short** window so partials appear while the mic is held.

Parakeet EOU 120M is a different, smaller true-streaming model. It is **not** what this product wants for the `parakeet` provider when the user expects the 0.6B TDT CoreML path.

MLX `parakeet-mlx` uses `transcribe_stream` (true streaming) and is often snappier for partials on Apple Silicon.

## Decision

- Provider `parakeet` loads **TDT 0.6B v3** and streams via `SlidingWindowAsrManager`.
- `parakeetChunkSeconds` maps to the window center stride (clamped ~0.4–3.0 s), with small right context for lower first-partial latency.
- Provider `parakeet-mlx` remains the true-streaming MLX alternative.

## Consequences

- Partials depend on window math: first update after roughly `chunk + right` seconds of audio.
- Accuracy on very short windows can be noisier than long-form defaults; 0.75 s is the product default.
- EOU models are unused by this provider.
