# Parakeet streams by re-transcribing and committing agreed words

## Status

Accepted (2026-09-26). Supersedes the streaming parts of 0004 and 0005.

## Context

Both Parakeet paths produced live text that kept rewriting itself:

- `parakeet-mlx` `transcribe_stream(context_size=(256, 256))` re-decodes the last 256 encoder frames (~20.5 s) on every step. The oldest part of that window has truncated context and degrades ("kind of buggy" → "body" → "big"). On a 38 s utterance this cost ~350 backspaces per update, 10,929 in total, and a 633-backspace rewrite on release when the separate batch transcription landed. Dropped or misapplied keystrokes turned that into duplicated text or deleted prompt text. Shrinking the draft window makes it stable but wrong (40–47% WER).
- The CoreML sliding window emitted text only while it extended what had been typed; after the first revision it froze until release, then rewrote everything.

## Decision

- Parakeet streaming is **LocalAgreement-2** over full-attention batch passes (`local_agreement.py`, `LocalAgreementStreamer.swift` — kept in step). Every `parakeetChunkSeconds` (clamped 0.4–1.5 s, default 0.5 s) the trailing buffer is re-transcribed; words matching the previous pass are committed. A word's trailing punctuation commits only once the next word agrees; punctuation-only flips commit after three agreeing passes; zero-duration or same-frame words at the end of a live pass (the decoder inventing an ending for cut-off audio) are dropped. The buffer is trimmed at committed sentence ends, so passes stay ~10 s or shorter.
- Runtimes deliver `{committed, draft}` snapshots (`transcript.snapshot` on the WebSocket). Committed text is append-only; release extends it.
- The app's `DictationTypist` is the single owner of what was typed. It never deletes committed text and never attempts a correction over 120 backspaces. When one would be needed, it holds until committed text covers the stale draft, then resumes after it. Transcript events drain through one ordered stream, and audio is gated so nothing is sent after the final commit.

## Consequences

- Measured on synthetic speech (38–88 s, several voices, pauses, 15 dB noise): 0.6–2.4% WER vs 0–2.4% for whole-clip batch; 83–245 backspaces per utterance with a largest correction ≤ 57 characters; ~100–130 ms per pass on an M1 Max; first text ~0.5 s after speech starts.
- Committed words cannot be corrected by later context. A word misheard with two passes agreeing stays (e.g. "overwrites" → "overrides"). This is the price of never rewriting what the user has seen.
- `parakeet-mlx`'s `transcribe_stream` is unused.
