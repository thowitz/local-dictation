# local-dictation

Native, fully local dictation for macOS — a drop-in replacement for system Dictation. Press the 🎤 mic key to start/stop; words stream into the focused app while you speak. Powered by **Voxtral-Mini-4B-Realtime** (6-bit MLX) via [voxmlx](https://github.com/awni/voxmlx) on Apple Silicon.

Two processes, one repo: a Python WebSocket ASR server (`server/`) and a menu-bar Swift app (`app/`) that captures audio, inserts text, and supervises the server.

## Requirements

- Apple Silicon Mac
- macOS 15 or later
- [uv](https://docs.astral.sh/uv/) (Python package manager)
- Xcode Command Line Tools (`xcode-select --install`) — Swift 6 toolchain

## Quick start

```bash
make server   # uv sync (incl. dev tools) in server/
make model    # pre-download ~3.5 GB HF model (optional but recommended)
make app      # swift build -c release
make run      # launch the menu-bar app
```

The app starts and watches `server/.venv/bin/local-dictation-serve` itself (default port **8471**, model `mlx-community/Voxtral-Mini-4B-Realtime-6bit`). You do not need to run the server in a separate terminal for normal use.

Install the mic-key remap from the app menu (**Install mic-key remap…**), or manually:

```bash
make remap    # 🎤 → F13
make unremap  # restore stock mapping
```

## Permissions

Grant these before first use (the app prompts where it can):

| Permission | System Settings path | Why |
|---|---|---|
| **Microphone** | System Settings → Privacy & Security → Microphone | Audio capture |
| **Accessibility** | System Settings → Privacy & Security → Accessibility | Caret location (AX) + text insertion |
| **Input Monitoring** | System Settings → Privacy & Security → Input Monitoring | `hidutil` mic-key remap on macOS 15+ |

After granting, quit and relaunch the app if a permission was denied on first try.

### Required: turn off system Dictation shortcut

Otherwise macOS will steal the mic key:

1. **System Settings → Keyboard → Dictation → Shortcut → Off**
2. Also check **System Settings → Apple Intelligence & Siri** (or Siri) and disable any **press-and-hold F5** / mic-key binding

## Usage

- Press **🎤** (after remap) to start dictation — a blue mic indicator appears at the caret.
- Press **🎤** again to stop — trailing tokens flush, then the indicator dismisses.
- Press **Esc** while active to cancel immediately (already-typed text stays; in terminal buffer mode the buffer is discarded).
- Menu bar: Start/Stop, remap install, Launch at Login, permission status, Quit.

### Terminal mode

In terminal-like apps (Terminal, iTerm2, Ghostty, Warp, kitty, Alacritty, and AX-detected shells), text is **buffered and inserted once on stop**. Newlines/tabs become spaces so a mid-stream newline cannot submit a command.

## Makefile targets

| Target | What it does |
|---|---|
| `make server` | `uv sync --group dev` in `server/` |
| `make app` | `swift build -c release` in `app/` |
| `make run` | Build if needed, launch `LocalDictation` (app supervises server) |
| `make model` | Pre-download the default Hugging Face model |
| `make remap` / `make unremap` | Direct `hidutil` UserKeyMapping set/clear |
| `make smoke` | Generate test WAV, briefly start server, run `ws_smoke.py` |
| `make lint` | `ruff check`, `ruff format --check`, `ty check` |
| `make clean` | Remove `.build`, `.venv`, caches (not the HF model cache) |

### Smoke test (two-terminal alternative)

```bash
# Terminal A
server/.venv/bin/local-dictation-serve --port 8471

# Terminal B (after /health is up)
cd server
uv run python scripts/make_test_wav.py test.wav
uv run python scripts/ws_smoke.py test.wav
```

## Troubleshooting

**Secure input** — Password fields and some elevated prompts enable Secure Input; synthetic keystrokes are dropped. The app refuses to start dictation and warns you. Click out of the secure field and retry.

**Server restarting** — The app restarts `local-dictation-serve` on crash with backoff. Check Console / menu-bar error state, or run the binary by hand to see stderr. Confirm `make server` created `server/.venv/bin/local-dictation-serve`.

**Model download on first run** — Without `make model`, the first server start downloads ~3.5 GB from Hugging Face. The menu bar shows a downloading state while progress lines appear on stderr. Prefer `make model` beforehand on a good network.

**Mic key still opens system Dictation** — Remap not installed, or Dictation shortcut still on. Run `make remap` (or use the app menu), set Shortcut → Off, and grant Input Monitoring if `hidutil` fails on macOS 15+.

**Remap lost after reboot** — Install the LaunchAgent from the app UI (`~/Library/LaunchAgents/com.local-dictation.keyremap.plist`). Plain `make remap` is session-only.

## Licenses / attribution

This project builds on MIT-licensed work:

- **[voxmlx](https://github.com/awni/voxmlx)** (MIT) — MLX Voxtral realtime ASR core
- **[voxmlx fork](https://github.com/T0mSIlver/voxmlx)** (MIT) — FastAPI WebSocket server, streaming session, watchdog, encoder-cache bound patterns adapted into `server/`
- **[localvoxtral](https://github.com/T0mSIlver/localvoxtral)** (MIT) — Swift patterns for insertion, terminal detection, audio capture, and process supervision (reimplemented, not copied wholesale)
- **[CursorBounds](https://github.com/Aeastr/CursorBounds)** (MIT) — caret-bounds / AX fallback approach (vendored as approach, not as a dependency)

See upstream repositories for full license text.
