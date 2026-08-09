# Parakeet partial transcripts and MLX backend

Local Dictation extends Parakeet with two additions: periodic partial text while
the user speaks, and an optional MLX backend.

CoreML Parakeet re-transcribes the growing utterance every
`parakeetChunkSeconds` of new audio and emits only the stable text suffix. The
MLX path uses `parakeet-mlx` `transcribe_stream` inside the Python WebSocket
server under provider `parakeet-mlx`. Both keep the same dictation-session and
speech-runtime lifecycles as Voxtral. We rejected true TDT token streaming for
CoreML because FluidAudio exposes batch and sliding-window APIs, not a
cache-aware TDT stream for this model.
