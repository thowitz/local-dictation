# local-dictation

Native, fully local dictation for macOS — a drop-in replacement for system Dictation. Use the 🎤 mic key in **Hold to Talk** or **Press to Toggle** mode (menu: Mic Key Mode); words stream into the focused app while you speak. Powered by **Voxtral-Mini-4B-Realtime** (6-bit MLX) via [voxmlx](https://github.com/awni/voxmlx) on Apple Silicon.

Two processes, one repo: a Python WebSocket ASR server (`server/`) and a menu-bar Swift app (`app/`) that captures audio, inserts text, and supervises the server.

## Requirements

### Build (development / packaging)

- Apple Silicon Mac (arm64)
- macOS 15 or later
- [uv](https://docs.astral.sh/uv/) (Python package manager)
- Xcode Command Line Tools (`xcode-select --install`) — Swift 6 toolchain

### Packaged runtime (installed `.app`)

- Apple Silicon Mac, macOS 15+
- Network and roughly **4 GB free** for the first model download (or pre-seed with `make model` on a build machine that shares the same HF cache)
- **No** Python, uv, or Xcode required on the end-user machine

## Quick start (development)

```bash
make server   # uv sync (incl. dev tools) in server/
make model    # pre-download ~3.5 GB HF model (optional but recommended)
make app      # swift build -c release
make run      # launch the menu-bar app (raw SwiftPM product)
```

This development path intentionally uses the repo venv (`server/.venv/bin/local-dictation-serve`). On launch the app **resolves** a server launch command (see [Server launch command](#server-launch-command) below). You do not need to run the server in a separate terminal for normal use.

## Packaged app (`make package`)

Build a Finder-launchable, ad-hoc–signed app that embeds a relocatable CPython + MLX server runtime:

```bash
make package         # → dist/LocalDictation.app
make package-check   # layout, signatures, bundled `python3 -m … --help`
```

### Install

```bash
# Finder: drag dist/LocalDictation.app into /Applications
# or:
ditto dist/LocalDictation.app /Applications/LocalDictation.app
open /Applications/LocalDictation.app
```

Grant **Microphone**, **Accessibility**, and **Input Monitoring** to the **installed** `/Applications/LocalDictation.app` (not the raw `make run` binary). TCC grants are signature/path-specific; preferences share the `com.omcdowell.LocalDictation` defaults suite across raw and packaged runs.

**Launch at Login** is offered only from the installed `/Applications` copy and may require approval under **System Settings → General → Login Items**. Raw `make run` builds and uninstalled bundles show “install in /Applications first”.

The package is **arm64** and **ad-hoc signed**, not notarized. A quarantined copy transferred to another Mac may need the normal **right-click → Open** / Open Anyway flow. Do not disable Gatekeeper globally.

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

- **Hold to Talk** (Mic Key Mode): hold **🎤** to dictate — a blue mic indicator appears at the caret; release to stop and flush trailing tokens.
- **Press to Toggle** (default): press **🎤** to start; press again to stop and flush.
- **⌥⌘D** and the menu Start/Stop item always toggle, regardless of mic-key mode.
- Press **Esc** while active to cancel immediately (already-typed text stays; in terminal buffer mode the buffer is discarded).
- Menu bar: Start/Stop, Mic Key Mode, remap install, Launch at Login, permission status, Quit.

### Terminal mode

In terminal-like apps (Terminal, iTerm2, Ghostty, Warp, kitty, Alacritty, and AX-detected shells), text is **buffered and inserted once on stop**. Newlines/tabs become spaces so a mid-stream newline cannot submit a command.

## Server launch command

The app does **not** hard-code a repo path. At each start/retry it resolves a `ServerLaunchCommand` in this order:

1. **Absolute override** — if `serverExecutable` is set in config, that path wins. It must be absolute (after `~` expansion) and executable. An invalid override **fails authoritatively** (no fallback to packaged/dev candidates).
2. **Packaged bundle helper** — when running from a `.app` bundle:
   ```
   <LocalDictation.app>/Contents/Helpers/LocalDictationServer/bin/python3 \
     -I -B -u -m local_dictation_server.server
   ```
   `make package` installs this helper. A packaged app with a missing/broken helper **does not** fall through to Application Support or a nearby checkout.
3. **Application Support** — `~/Library/Application Support/LocalDictation/server/bin/local-dictation-serve`, then `…/server/.venv/bin/local-dictation-serve`.
4. **Development checkout** — walk ancestors from the running executable for a repo root that contains both `server/` and `app/`, then use `server/.venv/bin/local-dictation-serve`.

### Config override

Config lives at `~/Library/Application Support/LocalDictation/config.json` and is read **at startup** — edits require an **app relaunch**.

A minimal override is enough (port and model default):

```json
{"serverExecutable": "/abs/path/to/serve"}
```

- Path must be absolute after `~` expansion and must be executable.
- Optional keys: `port` (default `8471`), `model` (HF id). An invalid `port` is reported rather than silently defaulted.

## Server status, errors, and recovery

The menu bar shows concise server rows: **Starting…**, **Downloading model…** (with percent when known), **Restarting N/5…**, Ready, or a short failure reason.

When the server is restarting or failed:

- **Show Server Details…** — launch command/source, port, timing, download progress, exit facts, and a **bounded recent stderr tail**, with **Copy Details**.
- **Retry Server** — re-resolves the launch command and restarts supervision **without** opening the mic.

Port-in-use, launch failure, readiness timeout, and repeated exits each show a concise reason plus a next step. Recent stderr is visible and copyable in-app — you do not need Console.app for normal diagnosis.

### First-download behavior

On first launch (empty Hugging Face cache), the supervised server downloads the default model (~3.5 GB) into `~/.cache/huggingface` (shared with `make model`, raw runs, and packaged runs — no `HF_HOME` override). Interrupted downloads resume from that cache.

Startup is **activity-aware**: before any download output, readiness fails after **10 minutes** of silence or a **1 hour** absolute cap. Once download progress is observed, the absolute window extends to **~2 hours**, but **10 minutes** without output still fails (reported as a stalled-download timeout when the extended cap fires). **`/health` HTTP 200 is the sole readiness signal** — stdout markers are diagnostic only.

Prefer `make model` beforehand on a good network so the first supervised start does not download cold.

## Makefile targets

| Target | What it does |
|---|---|
| `make server` | `uv sync --group dev` in `server/` |
| `make app` | `swift build -c release` in `app/` |
| `make run` | Build if needed, launch `LocalDictation` (app supervises server) |
| `make model` | Pre-download the default Hugging Face model |
| `make package` | Build signed `dist/LocalDictation.app` (arm64, embedded Python/MLX) |
| `make package-check` | Verify package layout, signatures, and bundled server `--help` |
| `make remap` / `make unremap` | Direct `hidutil` UserKeyMapping set/clear |
| `make smoke` | Generate test WAV, briefly start server, run `ws_smoke.py` |
| `make test` | Swift tests in `app/` + Python `unittest` in `server/tests/` |
| `make lint` | `ruff check`, `ruff format --check`, `ty check` |
| `make clean` | Remove `.build`, `.venv`, `.package-build/`, `dist/`, caches (not the HF model cache) |

### Testing

```bash
make test
```

Runs both suites and fails if either fails:

- **Swift** — Swift Testing under `app/`. On Command Line Tools–only Macs (no full Xcode), `Testing.framework` is not on `swift test`’s default search path; `make test` sets the developer Frameworks/library paths automatically when that framework is present.
- **Python** — `uv run python -m unittest discover -s tests -v` in `server/` (after `make server`).

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

**Server failed / restarting** — Use **Show Server Details…** (and Copy Details) for the launch command, port, exit facts, and recent stderr. **Retry Server** after fixing the underlying problem (override path, port conflict, `make server`, etc.). In development, confirm `make server` created `server/.venv/bin/local-dictation-serve`.

**Port already in use** — Stop the other process on the configured port, or change `port` in `config.json` and relaunch. The app probes the port before spawning and maps a child `port_in_use` sentinel the same way.

**Model download on first run** — Without `make model`, the first server start downloads ~3.5 GB from Hugging Face. The menu shows Downloading while recognized progress lines appear; silence (or the absolute cap) times out with details. Prefer `make model` beforehand.

**Mic key still opens system Dictation** — Remap not installed, or Dictation shortcut still on. Run `make remap` (or use the app menu), set Shortcut → Off, and grant Input Monitoring if `hidutil` fails on macOS 15+.

**Remap lost after reboot** — Install the LaunchAgent from the app UI (`~/Library/LaunchAgents/com.local-dictation.keyremap.plist`). Plain `make remap` is session-only.

## Licenses / attribution

This project builds on MIT-licensed work:

- **[voxmlx](https://github.com/awni/voxmlx)** (MIT) — MLX Voxtral realtime ASR core
- **[voxmlx fork](https://github.com/T0mSIlver/voxmlx)** (MIT) — FastAPI WebSocket server, streaming session, watchdog, encoder-cache bound patterns adapted into `server/`
- **[localvoxtral](https://github.com/T0mSIlver/localvoxtral)** (MIT) — Swift patterns for insertion, terminal detection, audio capture, and process supervision (reimplemented, not copied wholesale)
- **[CursorBounds](https://github.com/Aeastr/CursorBounds)** (MIT) — caret-bounds / AX fallback approach (vendored as approach, not as a dependency)

See upstream repositories for full license text.
