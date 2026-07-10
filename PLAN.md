# local-dictation — native drop-in replacement for macOS dictation

## Context

Build a fully local dictation app in `/Users/oxxxx/Code/local-dictation` (currently empty) that replaces macOS dictation end-to-end:

- **Same trigger key**: the 🎤 mic key on F5 (MacBook Pro M3 Max function row). Configurable **Hold to Talk** or **Press to Toggle** (default) via the Mic Key Mode menu; ⌥⌘D and menu Start/Stop always toggle.
- **Same UX**: a blue mic indicator appears at the text caret where text will land; words stream into the focused app *while speaking*.
- **Engine**: Voxtral-Mini-4B-Realtime-2602 (6-bit MLX) — the most accurate streaming ASR that runs on Apple Silicon (FLEURS EN 4.9% WER @ 480ms delay). Built on **voxmlx** (MIT) + the ~790 LOC of server/memory optimizations from **localvoxtral's voxmlx fork** (MIT). Swift UI written fresh, native, minimal.

## Architecture

Two processes, one repo:

```
local-dictation/
├── server/                          # Python engine (uv project)
│   ├── pyproject.toml               # deps: voxmlx (upstream pip), fastapi, uvicorn, numpy
│   └── src/local_dictation_server/
│       ├── server.py                # adapted from voxmlx-fork (MIT attribution)
│       ├── realtime_audio.py        # from voxmlx-fork
│       ├── _watchdog.py             # from voxmlx-fork
│       └── audio_constants.py       # from voxmlx-fork
├── app/                             # SwiftPM executable, macOS 15+, LSUIElement
│   ├── Package.swift
│   └── Sources/LocalDictation/
│       ├── App.swift                # NSStatusItem menu bar host, state machine
│       ├── MicKeyManager.swift      # hidutil remap + F13 hotkey
│       ├── ServerSupervisor.swift   # spawn/health-check/restart python server
│       ├── AudioCapture.swift       # mic → 16kHz mono Int16 chunks
│       ├── RealtimeClient.swift     # WebSocket, OpenAI Realtime subset
│       ├── TextInserter.swift       # CGEvent unicode typing at caret
│       ├── CaretLocator.swift       # AX caret bounds + fallback chain
│       └── IndicatorPanel.swift     # blue mic NSPanel at caret
├── Makefile                         # build, run, install-remap, uninstall
└── README.md
```

**Dictation flow**: mic key down (hold mode) or press (toggle mode) → indicator appears at caret + mic capture starts (start sound) → server streams `response.audio_transcript.delta` tokens → typed live into the focused app → mic key up / second press → `input_audio_buffer.commit {final:true}` → trailing tokens flush → indicator dismisses (stop sound). Esc while active = stop immediately (no flush wait; already-typed text stays; in terminal buffer mode the buffer is discarded).

**Session/connection model**: one **persistent WebSocket** opened once the server is healthy, reused across dictation sessions — `input_audio_buffer.clear` resets between toggles (avoids per-toggle connect latency); auto-reconnect with backoff if it drops.

**Insertion modes**: stream-live everywhere, EXCEPT terminal-like targets (bundle-ID set + AX probe) which **buffer and insert once on stop** with newlines/tabs converted to spaces — word-by-word streaming into a shell prompt is too risky.

## Verified platform facts (from research)

1. **Mic key** = HID Consumer Page 0x0C usage 0xCF ("Voice Command"), 64-bit `0xC000000CF`. It cannot be reliably intercepted by event taps (system consumes it first). Proven approach (Spokenly, Handy): `hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xC000000CF,"HIDKeyboardModifierMappingDst":0x700000068}]}'` remaps it to **F13**, which the app registers as an ordinary global hotkey (Carbon `RegisterEventHotKey` — consumes the event, no extra permissions). Remap doesn't survive reboot → LaunchAgent plist `~/Library/LaunchAgents/com.local-dictation.keyremap.plist` with `RunAtLoad`. Undo: `hidutil property --set '{"UserKeyMapping":[]}'`. User must also set System Settings → Keyboard → Dictation → Shortcut → **Off** (detect + prompt on first run; also check Siri's press-and-hold F5 under Apple Intelligence & Siri).
2. **Caret position**: AX API — systemwide element → `kAXFocusedUIElementAttribute` → `kAXSelectedTextRangeAttribute` → `AXUIElementCopyParameterizedAttributeValue(kAXBoundsForRangeParameterizedAttribute)`; CG coords (flip Y for AppKit). Fallback chain caret → focused-field bounds → mouse pointer (pattern from MIT CursorBounds package, github.com/Aeastr/CursorBounds — vendor the approach, not the dependency). Electron/web apps may return bogus bounds → fallbacks handle it.
3. **voxmlx** (MIT, ~1.8k LOC): import `load_model`, `VoxtralRealtime.encode_step/decode`, `RotatingKVCache`, `log_mel_spectrogram_step`, `_build_prompt_tokens` as-is. 80ms/token cadence; `num_delay_tokens=6` ≈ 480ms delay (quality sweet spot); default model `mlx-community/Voxtral-Mini-4B-Realtime-6bit` (~3.5 GB).
4. **voxmlx-fork deltas worth keeping** (all MIT, ~790 LOC): `StreamingSession` (stream loop refactored to `feed_audio()/finalize()/reset()` with encapsulated state); FastAPI WS server `/v1/realtime` speaking OpenAI Realtime subset (`input_audio_buffer.append` base64-PCM16 → `response.audio_transcript.delta`; `commit {final:true}` → finalize → `.done`; `clear` → reset); `/health`; `VOXMLX_READY` stdout marker; `--parent-pid` watchdog; scratch-buffer chunk planning; **encoder KV cache bounded to `encoder.sliding_window` (750) instead of 100k** — the fork patches model.py for this; we instead pre-create the bounded cache list in `StreamingSession.__init__` and pass it into `encode_step` so upstream voxmlx stays an unmodified pip dep (verify `encode_step`'s cache-creation path allows this at implementation time; if not, subclass `VoxtralRealtime`).
5. **localvoxtral Swift patterns to reimplement** (not copy wholesale; MIT so borrowing specifics is fine):
   - Text insertion: `CGEvent` + `keyboardSetUnicodeString`, chunked at 20 UTF-16 units, posted to `.cgAnnotatedSessionEventTap` (their `TextInsertionService.postUnicodeTextEvents`). AX `kAXValueAttribute` writes are unsuitable for streaming (whole-value replacement) — keyboard path only for v1.
   - Terminal safety: bundle-ID set (Terminal, iTerm2, Ghostty, Warp, kitty, Alacritty) + AX probe (`kAXValueAttribute` not settable ⇒ terminal-like) → convert newlines/tabs to spaces.
   - Secure input: `IsSecureEventInputEnabled()` → warn + refuse to start (synthetic keys are dropped anyway).
   - Audio: 16 kHz mono Int16 via `AVAudioConverter` (quality `.max`). They use CoreAudio AUHAL; v1 uses the simpler `AVAudioEngine` input tap + converter, AUHAL only if device-change handling proves flaky.
   - Supervision: `Process` with `--model --port --parent-pid`, poll `http://127.0.0.1:<port>/health` until 200 with backoff-restarts and stderr capture (their `BackendProcessSupervisor`). Port: 8471.

## Implementation steps

### 1. Python server package (`server/`)
- `uv init`; deps: `voxmlx`, `fastapi`, `uvicorn`, `numpy`. Entry point `local-dictation-serve`.
- Copy the fork's 4 files with MIT attribution header; rename imports to package-relative; apply the encoder-cache bound session-side (see fact 4).
- Keep temperature 0.0 (greedy), model configurable via `--model`, default 6-bit.
- Smoke test: `scripts/ws_smoke.py` — stream a WAV over the WS protocol, assert deltas + final text.

### 2. Swift app skeleton (`app/`)
- SPM executable, `LSUIElement` (menu bar only, no Dock). Status item: mic SF Symbol, state-tinted (idle/starting/**downloading**/listening/error), menu: Start/Stop Dictation, "Install mic-key remap…", **"Launch at Login" toggle (`SMAppService.mainApp`)**, permission status rows, Quit.
- `ServerSupervisor` (launch `server/.venv/bin/local-dictation-serve` — path from config with repo default), `RealtimeClient` (persistent connection, see flow), `AudioCapture`; wire so dictation logs transcript deltas to console first.
- **Model download UX**: `make model` pre-downloads via `huggingface_hub.snapshot_download`; the supervisor also parses hf-hub progress lines from server stderr and shows "Downloading model… N%" in the menu bar instead of appearing hung on first run.

### 3. Insertion + mic-key modes
- `TextInserter` (chunked unicode CGEvents, terminal newline handling, secure-input check).
- Toggle state machine on a temporary dev hotkey (⌥⌘D) and menu Start/Stop: press → capture+insert; press → commit-final, flush, stop.
- F13 / remapped 🎤 supports **Hold to Talk** and **Press to Toggle** (persisted Mic Key Mode preference); mode is latched on key-down.

### 4. Mic key takeover
- `MicKeyManager`: install/remove the hidutil remap (run `hidutil` via `Process`), write/remove the LaunchAgent plist, register F13 via `RegisterEventHotKey`.
- **hidutil failure path**: on macOS 15+ hidutil may need an Input Monitoring grant for the invoking binary — detect a failed/ineffective remap (`hidutil property -g UserKeyMapping` after set) and show precise guidance (grant Input Monitoring to the app in Privacy & Security, retry).
- First-run checks: macOS Dictation shortcut still on? Siri hold-F5 bound? → alert with deep-link to the exact System Settings panes (`x-apple.systempreferences:`).

### 5. Caret indicator
- `CaretLocator` with the 3-step fallback chain; `IndicatorPanel`: non-activating floating `NSPanel` (`.nonactivatingPanel`, `.floating` level, ignores mouse, **collectionBehavior `.canJoinAllSpaces` + `.fullScreenAuxiliary`** so it shows over full-screen apps and every Space), SwiftUI content replicating the system look: rounded capsule, `mic.fill` in `Color(nsColor: .controlAccentColor)`/system blue, subtle pulse while listening, brief "processing" state during final flush. Reposition on caret move (poll ~10 Hz while active; cheap AX call).
- **Sounds**: play system-dictation-style start/stop pops (`NSSound`) on toggle; menu option to disable.

### 6. Polish + packaging
- Error surfacing (server died, model downloading, secure input, no AX permission) via status item + indicator states.
- `Makefile`: `make server` (uv sync), `make app` (swift build), `make run`, `make remap` / `make unremap`, `make install` (copy .app to /Applications later if wanted).
- README: permissions walkthrough (Microphone + Accessibility), dictation-shortcut-off step, licenses/attribution (voxmlx MIT, localvoxtral-fork MIT).

## Verification

1. `server/scripts/ws_smoke.py` passes: WAV in → correct transcript deltas + final out.
2. `swift build` clean; app launches to menu bar; server reaches `ready` (health 200) with model resident.
3. E2E with dev hotkey: dictate into TextEdit — words appear while speaking; second press flushes tail and stops. Repeat in Safari address bar, VS Code, and iTerm2 (newline conversion, no accidental submits).
4. Mic key: after remap install, 🎤 key follows the selected Mic Key Mode (hold or toggle); system dictation UI never appears; key survives reboot (LaunchAgent); `make unremap` restores stock behavior. ⌥⌘D remains toggle.
5. Indicator appears adjacent to the caret in TextEdit/Notes; falls back near the field/mouse in Chrome/Electron apps without crashing.
6. Latency feel-check: first word ≲1s after speech starts (480ms algorithmic + decode), steady 80ms cadence after; stop-press flush < 1s.
7. Long-session memory check: dictate ~10 min continuously; server RSS stays bounded (encoder cache fix effective).

## Out of scope for v1
LLM polishing, overlay-buffer/review mode, settings UI (config file + Mic Key Mode menu only), notarized .app distribution, multi-language switching UI (model handles 13 languages transparently).

## Reference material for the implementing agent
- Read-only clones (re-clone if missing): `/private/tmp/claude-501/-Users-oxxxx-Code-local-dictation/107a850e-5056-4d62-a66d-e80b7b2e07ad/scratchpad/{voxmlx, voxmlx-fork, localvoxtral}` — upstream `github.com/awni/voxmlx`, fork `github.com/T0mSIlver/voxmlx`, app `github.com/T0mSIlver/localvoxtral`. All MIT.
- Files to port from voxmlx-fork: `voxmlx/server.py` (545 LOC), `voxmlx/realtime_audio.py` (201), `voxmlx/_watchdog.py` (39), `voxmlx/audio_constants.py` (6). The fork's only other substantive change is the encoder-cache bound (`model.py:122`: `RotatingKVCache(100_000)` → `RotatingKVCache(self.encoder.sliding_window)`).
- localvoxtral files worth reading for patterns (do not copy wholesale): `Sources/localvoxtral/TextInsertionService.swift` (`postUnicodeTextEvents`, `pasteUsingCommandV`), `TerminalTargetDetector.swift`, `MicrophoneCaptureService.swift` (AVAudioConverter usage), `Backends/BackendProcessSupervisor.swift` (supervise/readiness/backoff), `RealtimeAPIWebSocketClient.swift` + `BaseRealtimeWebSocketClient.swift` (protocol framing).
- Verification target machine: MacBook Pro M3 Max, 48 GB, macOS 26.5. GUI permission grants (Microphone, Accessibility, Input Monitoring) and System Settings changes require the human user — implement, then list the exact grants needed rather than blocking on them.
