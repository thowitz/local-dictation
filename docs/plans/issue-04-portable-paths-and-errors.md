# Issue #4 implementation plan — portable server paths and in-app failures

Issue: `omcdowell/local-dictation#4` — **Ops: portable server path and in-app errors**
Planning baseline: `main` at `17e3091` (all `origin/feat/{1..5}-*` refs currently point at the same commit).
Scope: server launch-command discovery, generation-safe supervision, structured diagnostics, and menu-bar surfacing. #4 establishes shared seams and tests; it does **not** assemble/sign a distributable app (#5), implement press/release input modes (#2), add idle scheduling (#1), or build onboarding (#3).

## 1. Current state and exact code paths

### Configuration and executable discovery

- `app/Sources/LocalDictation/AppConfig.swift`
  - `AppConfig.load()` reads `~/Library/Application Support/LocalDictation/config.json`, but silently falls back to defaults on any read/decode error.
  - Synthesized `Codable` makes `port` required. A minimal config containing only `serverExecutable` does not decode.
  - `AppConfig.resolvedServerExecutable` gives a non-empty `serverExecutable` override precedence, expands `~`, and otherwise always returns `compiledInRepoRoot/server/.venv/bin/local-dictation-serve`.
  - `AppConfig.compiledInRepoRoot` is `/Users/oxxxx/Code/local-dictation`; there is no actual relative dev, bundle-helper, or Application Support search.
  - Resolution assumes every server is directly executable with no argument prefix. That cannot represent the packaged Python invocation required by #5.
  - `healthURL` and `websocketURL` use loopback and `port` (default 8471).
- `app/Sources/LocalDictation/App.swift` uses `UserDefaults.standard`; there is no explicit stable defaults suite shared by future preferences.
- `AppLog` in `AppConfig.swift` uses subsystem `com.local-dictation`, while the integration contract requires the stable app identity/defaults suite `com.omcdowell.LocalDictation`.
- `MicKeyManager.launchAgentLabel` is already `com.local-dictation.keyremap`; that label is persisted externally and must remain unchanged for compatibility.

### Supervisor launch, readiness, output, and restart flow

- `app/Sources/LocalDictation/ServerSupervisor.swift`
  - `ServerSupervisor.start()` creates one main-actor `supervisionTask`; `stop()` cancels it, sends `terminate()`, immediately drops process/pipe references, and transitions to `.stopped` without waiting for process exit or output drain.
  - `supervise()` first calls `probeHealth()`. Any 200 from `/health` is reported as “port already in use,” but an unrelated listener without that endpoint is not detected before model load.
  - `spawn()` checks only `config.resolvedServerExecutable`, then launches `Process` with `--port`, `--parent-pid`, and optional `--model`. There is no `ServerLaunchCommand` abstraction or argument prefix.
  - `waitForReadiness()` treats either `sawReadyMarker` or HTTP 200 as ready. `server.py` emits `VOXMLX_READY` before uvicorn binds, so this can falsely transition to `.running` and obscure a bind failure.
  - Readiness uses a brittle absolute 600-second deadline. First download may be making visible progress when it is killed; conversely, the timeout failure has no last-activity, progress, executable, or stderr context.
  - `waitForExit()` checks `isRunning` and only then installs a termination handler. An exit in that gap can strand the continuation.
  - `consecutiveFailures` resets immediately on every `.ready`. A process that becomes healthy and crashes quickly can restart forever at attempt 1.
  - `.restarting(attempt:)` is collapsed by the app to generic “Starting”; no exit status, signal, retry limit, delay, command source, or output reaches the UI.
  - `appendOutput(data:isStderr:)` handles LF/CR and extracts percentages, but keeps no bounded stderr history. `clearProcess()` erases partial buffers; output is available only through `os.Logger`.
  - `extractPercent(from:)` accepts the first percentage in any stderr line, so unrelated percentages can become download progress.
  - There is no explicit TCP bind availability check, stable uvicorn `EADDRINUSE` classification, launch generation, or injectable process/health/clock seams.

### Server startup output

- `server/src/local_dictation_server/server.py`
  - `main()` eagerly calls `create_app()` (including model download/load), prints `VOXMLX_READY`, and only then calls `uvicorn.run()`, where the socket is bound.
  - A port collision is therefore discovered after expensive startup, and the marker does not mean `/health` is reachable.
  - Hugging Face/tqdm and Python/uvicorn diagnostics are emitted to stderr, which is the correct source for an in-app bounded tail and startup-activity observation.
  - `/health` returns `{"status":"ok"}` only when the loaded FastAPI app is being served; it is the existing authoritative readiness signal.

### State/UI propagation

- `app/Sources/LocalDictation/App.swift`
  - `DictationState` has `.starting`, `.downloading`, `.ready`, and `.error(String)`, but no restart-specific state and no typed distinction between server and app/permission failures.
  - `DictationController.handleServerState(_:)` maps `.launching`, `.waitingForReady`, and `.restarting` to generic `.starting`; `.failed(String)` becomes `.error(String)`.
  - During a non-terminal server restart, active audio/WebSocket work is not synchronously torn down by the server-state path and can race with the next launch.
  - `startDictation()` allows `.error` but does not call `supervisor.start()` from that state. After terminal failure, the enabled menu item does not actually restart the supervisor.
  - `AppDelegate` has disabled `statusItemLabel` and `serverStatusItem` rows. `refreshServerStatusRow(for:)` says only `Server: Error / restarting`; long error text is placed in the top menu title and is likely truncated.
  - There is no clickable details/copy action or explicit retry.
- `app/Sources/LocalDictation/RealtimeClient.swift`
  - It reconnects independently until `disconnect()` is called. The controller must suppress reconnect while the supervisor is between generations.

### Build/test/docs layout

- `app/Package.swift` has only the executable target; there is no shared Swift test target.
- `server/pyproject.toml` defines `local-dictation-serve`; no dependency change is required for #4.
- `Makefile` knows the checkout root and pre-checks the dev console script, masking the app’s hard-coded fallback during normal `make run`.
- `README.md` documents only `server/.venv/bin/local-dictation-serve` and Console/manual troubleshooting. It does not define launch-command precedence, override semantics, packaged helper command, or in-app details/retry.
- `PLAN.md` describes health polling, stderr capture, and download UI as intent; current code remains the source of truth.

## 2. Chosen design and shared contract

### 2.1 Stable identity foundation owned by #4

Add one internal identity namespace used by current code and all later issues:

- bundle/defaults identity: `com.omcdowell.LocalDictation`;
- explicit `UserDefaults(suiteName: "com.omcdowell.LocalDictation")` store for current sound/first-run keys and future #2/#1 preferences;
- `AppLog` subsystem: `com.omcdowell.LocalDictation`;
- compatibility exception: keep the existing LaunchAgent label `com.local-dictation.keyremap` exactly as-is.

#5 will put `com.omcdowell.LocalDictation` in the actual `Info.plist`; #3 will target that packaged identity. #4 does not create an app bundle.

### 2.2 General `ServerLaunchCommand`, not just an executable path

Introduce:

```swift
struct ServerLaunchCommand: Equatable, Sendable {
    let executableURL: URL
    let argumentPrefix: [String]
    let source: ServerLaunchCommandSource
}
```

`ServerSupervisor.spawn()` must set `Process.executableURL` to `command.executableURL` and build arguments as:

```swift
command.argumentPrefix
+ ["--port", String(config.port),
   "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
+ optionalModelArguments
```

This keeps current console scripts working while supporting a packaged isolated Python module invocation without a duplicate #5 launcher path.

### 2.3 Deterministic, testable command resolution

Add a small `ServerLaunchCommandResolver`. Its production wrapper receives `Bundle.main.executableURL`, `AppConfig.supportDirectoryURL`, and `FileManager.default`; tests inject synthetic roots/filesystem checks.

Use strict precedence:

1. **Explicit config override (authoritative)**
   - `serverExecutable` after `~` expansion;
   - absolute, existing, executable;
   - command prefix `[]`, source `.override`;
   - if configured but invalid, fail instead of silently selecting another command.
2. **Packaged helper command (defined now, assembled by #5)**
   - executable: `<LocalDictation.app>/Contents/Helpers/LocalDictationServer/bin/python3`;
   - exact prefix: `[-I, -B, -u, -m, local_dictation_server.server]`;
   - source `.bundleHelper`;
   - derive `Contents` from the running `…/Contents/MacOS/LocalDictation` URL; do **not** search `Contents/Resources/server` and do not define a bundled console-script contract.
3. **Application Support command**
   - `~/Library/Application Support/LocalDictation/server/bin/local-dictation-serve`, then `server/.venv/bin/local-dictation-serve`;
   - prefix `[]`, source `.applicationSupport`.
4. **Development checkout command**
   - bounded ancestor walk from the running raw SPM executable;
   - identify root by both `app/Package.swift` and `server/pyproject.toml`;
   - command `<repo>/server/.venv/bin/local-dictation-serve`, prefix `[]`, source `.development`;
   - support `.build/<triple>/debug|release` and `.build/debug|release` without assuming clone name/parent.

Return the command plus attempted-candidate diagnostics (missing versus non-executable). Never depend on current working directory or a compiled home path. Error/detail text should display the full command source, executable, and prefix.

Make `AppConfig` decode omitted keys with defaults so a minimal `serverExecutable` override works. Configuration remains startup-loaded; README will require relaunch after edits. No settings editor/live reload is added.

### 2.4 Structured diagnostics, bounded output, and startup activity

Replace string-only server failures with internal values:

- `ServerExit`: exit status/reason/signal, run duration, complete `ServerLaunchCommand`, last startup/download activity, and stderr tail.
- `ServerRestartStatus`: failed attempt, max (5), selected backoff, and latest exit.
- `ServerFailure.Kind`: at least `commandNotFound`, `commandNotExecutable`, `launchFailed`, `invalidPort`, `portInUse`, `portUnavailable`, `readinessTimedOut`, and `consecutiveExits`.

Each failure supplies a short menu summary, known next step, command/port/timing/exit facts, and bounded stderr.

Use an in-memory 8 KiB / 50-logical-line stderr tail. Parse bytes across chunks, split LF and CR, preserve split UTF-8, flush final partial content at EOF, and retain output across attempts in one supervision run with attempt separators. Clear it only when a new run starts, not during process cleanup.

Extract a `DownloadProgressParser` that recognizes Hugging Face/tqdm-shaped activity rather than any percentage. It returns known/unknown percent and an activity timestamp. Preserve this in timeout/exit details.

Use **activity-aware startup timeout behavior**:

- `/health` 200 is still the only readiness condition.
- Maintain `lastStartupActivity` from process launch; refresh it on non-empty stdout/stderr and recognized download progress. Generic output refreshes liveness but does not falsely change the UI to Downloading.
- Production policy uses a 600-second **inactivity** timeout, not a 600-second absolute launch deadline.
- Add a generous absolute safety cap (proposed 60 minutes) so a noisy, permanently unhealthy child cannot run forever.
- Timeout details distinguish “no output/health for 10 minutes” from the hard cap and include last output/progress time and percent.
- Both inactivity and absolute limits are policy-injected for deterministic tests.

#4 owns this mechanism and tests. #5 must validate it with the packaged helper and an empty model cache, adjusting tested policy constants in the shared mechanism if real packaged first-download behavior requires it; #5 must not add marker-based readiness or a second timeout loop.

Known remediation remains intentionally narrow:

- stable `port_in_use` sentinel or `EADDRINUSE` → stop owner or change `port`;
- Python import/module failures → `make server`/`uv sync` for dev, or reinstall the packaged app for `.bundleHelper`;
- HF/network/cache/disk failures → check network/disk and run `make model` in dev, then retry;
- otherwise show facts/tail without guessing.

### 2.5 Generation-safe process lifecycle

Retain native `Process`, `Task`, `URLSession`, and Darwin sockets, but make the loop testable and race-safe:

1. Resolve a fresh `ServerLaunchCommand` at the start of every supervision run/retry.
2. Validate `port` (`1...65535`) and attempt a loopback TCP bind with `SO_REUSEADDR` before every launch. Active listener → `portInUse`; other bind error → `portUnavailable`.
3. Install process termination observation before `run()`. Create a per-attempt generation and output collector; unwind readers/resources if launch throws.
4. Poll `/health`; **only HTTP 200** transitions to running. Stdout markers are diagnostic only.
5. Race health polling against process exit, startup-inactivity timeout, absolute startup cap, and cancellation.
6. Before exit classification, await stdout/stderr EOF so final uvicorn/Python lines are included.
7. On timeout/intentional stop, send `SIGTERM`, wait a bounded grace period (for example two seconds), then `SIGKILL` if needed; await exit/output before releasing references.
8. Port sentinel/late bind collision fails immediately. Other exits increment restart budget and emit structured restart state.
9. Do not reset failures merely on health. Reset after a 60-second healthy stability window, so repeated quick post-ready crashes reach five failures.
10. Keep existing exponential backoff (`0.5, 1, 2, 4, …`, cap 30 seconds), now surfaced with attempt/max/delay.
11. Gate every output, health, sleep, and termination callback by generation. Intentional stop/cancel never consumes restart budget or emits stale failure.

#4 provides a correct generic `stop()`/cancellation path and generation primitive because timeout, retry, and quit need it. It does **not** add idle desired-running policy. #1 later adds only the stop reason(s), desired-running state, and idle scheduling needed for unload/relaunch on top of this loop.

Also change `server.py` to reserve the configured socket before model creation. `_reserve_server_socket(host, port)` emits a stable `LOCAL_DICTATION_FATAL kind=port_in_use …` on `EADDRINUSE`, and the reserved socket is passed to `uvicorn.Server.run(sockets:[...])`. This closes the two-launcher race during model load. Remove/rename the misleading ready marker; `/health` remains authoritative.

### 2.6 Typed app state and native menu presentation

- `ServerSupervisor.State.restarting` carries `ServerRestartStatus`; `.failed` carries `ServerFailure`.
- Add `DictationState.restarting(ServerRestartStatus)`.
- Replace `.error(String)` with typed `DictationFailure.server(ServerFailure)` versus ordinary app failures, eliminating substring checks for secure input/Accessibility.

Presentation:

- starting/downloading/restarting: orange, concise status and server rows;
- restarting shows attempt/max and delay;
- ready/running retains current behavior;
- terminal failure: red, short summary only in menu titles.

Add below `serverStatusItem`:

- `Show Server Details…` during restart/failure, opening native `NSAlert` with remediation, full launch command/source, port/timing/progress/exit facts, bounded stderr, and `Copy Details` via `NSPasteboard`;
- `Retry Server` on terminal server failure, re-resolving/rechecking without opening the microphone.

Fix starting from a server error so it can retry and honor the existing pending `wantsListening` boolean. If the process dies while active, classify the dictation session as interrupted: stop audio, preserve text already inserted live, discard uninserted terminal-target text, end the indicator, unregister Esc, clear the current boolean intent, and disconnect `RealtimeClient` until the next `.running`. Recovery may return to Ready but must not reopen the microphone. This is narrow failure cleanup, not #2’s later explicit pending/active intent model. #4 does not alter Carbon key semantics or add a mic-mode preference.

## 3. File-by-file ordered #4 changes

1. **`app/Package.swift`**
   - Add the first and only shared Swift test target, `LocalDictationTests`, depending on `LocalDictation` at `Tests/LocalDictationTests`.
   - Later #5/#2/#1/#3 work adds tests/fixtures to this target; no issue creates another app test target.

2. **New: `app/Sources/LocalDictation/AppIdentity.swift`**
   - Define stable identity/defaults suite `com.omcdowell.LocalDictation` and a shared suite-backed defaults store.
   - Move `AppLog` to the stable subsystem or have it reference this constant.
   - Explicitly preserve `MicKeyManager`’s `com.local-dictation.keyremap` LaunchAgent label; do not rename installed plists/jobs.

3. **New: `app/Sources/LocalDictation/ServerLaunchCommand.swift`**
   - Define `ServerLaunchCommand` and `ServerLaunchCommandSource`.
   - Provide command-line/detail formatting used by diagnostics and tests.

4. **New: `app/Sources/LocalDictation/ServerLaunchCommandResolver.swift`**
   - Implement the exact precedence above and attempted-candidate diagnostics.
   - Accept injected executable URL, support/home roots, filesystem checks, and bounded ancestor traversal.
   - Return the packaged command as `Contents/Helpers/LocalDictationServer/bin/python3` plus exact `[-I,-B,-u,-m,local_dictation_server.server]` prefix.
   - Never search `Contents/Resources/server`.

5. **`app/Sources/LocalDictation/AppConfig.swift`**
   - Remove `compiledInRepoRoot` and `resolvedServerExecutable`.
   - Add defaulted custom decoding and port validation.
   - Add a thin command-resolution entry point; keep precedence in the resolver.
   - Keep support/config URLs and endpoint construction.

6. **New: `app/Sources/LocalDictation/ServerDiagnostics.swift`**
   - Define `ServerExit`, `ServerRestartStatus`, `ServerFailure`, bounded stderr collector, focused progress parser, startup activity snapshot, and small remediation classifier.
   - Keep types AppKit-free and `Equatable`/`Sendable` where required.

7. **`app/Sources/LocalDictation/ServerSupervisor.swift`**
   - Launch `ServerLaunchCommand.executableURL` with prefix plus current server arguments.
   - Add structured restart/failure states and internal injected `Policy`/dependencies: resolver, health probe, port probe, process factory/observer seam, sleep, and clock.
   - Implement health-only readiness, activity-aware inactivity/absolute limits, port preflight, pre-run termination observation, output EOF drain, bounded termination escalation, stability-aware retries, and generation guards.
   - Keep generic intentional stop/cancel correct, but do not add idle timers or a broad desired-running state machine.
   - Log command source/full invocation, PID/generation, startup activity, progress, port classification, exit, and state.

8. **`server/src/local_dictation_server/server.py`**
   - Reserve the socket before model creation, emit stable bind-failure output, pass it to `uvicorn.Server`, and close it on setup failure.
   - Remove/rename pre-bind `VOXMLX_READY`; keep `/health` unchanged.
   - Do not alter ASR/session behavior.

9. **`app/Sources/LocalDictation/App.swift`**
   - Route current preferences through the stable defaults suite.
   - Add typed failures/restart presentation, server details/copy/retry rows, and exact visibility/enabling.
   - Update `DictationController.handleServerState(_:)` for structured details and generation transition cleanup.
   - Add narrow retry handling to current `wantsListening`; do not implement #2’s key-up events, mic mode, or generalized intent model.

10. **Shared Swift tests under `app/Tests/LocalDictationTests/`**
    - `AppIdentityTests.swift`
    - `AppConfigTests.swift`
    - `ServerLaunchCommandResolverTests.swift`
    - `ServerDiagnosticsTests.swift`
    - `ServerSupervisorTests.swift`
    - Put reusable temporary executable, state recorder, fake clock/probe, and output fixtures in a shared test-support file for later issues.

11. **New: `server/tests/test_server_startup.py`**
    - Use stdlib `unittest` and loopback sockets to test reservation/stable port failure without model creation.

12. **`Makefile`**
    - Add `test`: shared Swift tests plus server stdlib tests.
    - Keep `make run`’s dev preflight, but do not inject paths/environment into the app.

13. **`README.md`**
    - Document command resolution order, full packaged helper command, minimal override, port remediation, activity-aware first-download behavior, and in-app details/copy/retry.
    - Say #4 recognizes the helper layout but `make package`/#5 creates it.
    - Add `make test`.

14. **No #4 changes expected**
    - `server/pyproject.toml`: entry point/dependencies stay.
    - `app/Sources/LocalDictation/RealtimeClient.swift`: existing connect/disconnect API is sufficient; change controller call sites.
    - `app/Sources/LocalDictation/MicKeyManager.swift`: do not rename `com.local-dictation.keyremap`.
    - `PLAN.md`: retain as historical project plan.

## 4. Cross-issue ownership boundaries

| Issue | Owned work after #4 |
|---|---|
| **#4** | Shared Swift test target/fixtures; stable identity/defaults foundation; `ServerLaunchCommand`; portable resolver; structured diagnostics; `/health`-only, activity-aware, generation-safe supervisor and test seams; in-app server details/retry. |
| **#5** | Consume/extend #4 resolver and supervisor; actual `.app` assembly; self-contained Python runtime at `Contents/Helpers/LocalDictationServer`; package the module so isolated `python3 -I -B -u -m local_dictation_server.server` works; signing, `Info.plist` with `com.omcdowell.LocalDictation`/`LSUIElement`, packaging/install verification, first-download validation, and installed-app `SMAppService` behavior. No duplicate launcher/resolver/supervisor. |
| **#2** | Carbon press **and release** delivery; mic mode preference in shared defaults; explicit pending/active input intent; default mic-key mode remains **press-to-toggle** and hold-to-talk is opt-in; dev hotkey and menu action remain toggle. Adds tests/fixtures to `LocalDictationTests`. |
| **#1** | After #2, idle timer/config and desired-running intentional unload/relaunch layered onto #4 supervision and #2 intent. Add only missing stop-reason/generation handling; do not create another broad supervisor/client rewrite. Reuse shared tests. |
| **#3** | Guided checklist against packaged identity/final menu; use `com.omcdowell.LocalDictation`; consume #4 diagnostics and #2 preferences rather than duplicating them; preserve compatible remap label. Reuse shared tests. |

## 5. Tests and acceptance-criterion verification

Run `make test` after each #4 commit.

### Shared identity/command resolver tests

- Defaults suite and logging identity equal `com.omcdowell.LocalDictation`; remap label remains `com.local-dictation.keyremap`.
- Explicit override exists/executable → command with empty prefix wins all lower candidates.
- Invalid/non-executable override → authoritative structured failure, no fallback.
- Bundle helper beats Application Support/dev and resolves exactly:
  - executable `Contents/Helpers/LocalDictationServer/bin/python3`;
  - prefix `-I -B -u -m local_dictation_server.server` in that order.
- Assert no candidate contains `Contents/Resources/server`.
- Application Support order is deterministic; dev works from triple and shorthand `.build` layouts at arbitrary roots.
- No candidate lists every attempt and no current developer home.
- `~` uses injected home.
- Minimal override JSON defaults port/model; explicit values decode; invalid port is actionable.
- Supervisor argument assembly puts prefix before module arguments and appends `--port`, `--parent-pid`, and optional `--model` after the module name.

### Diagnostics/output/activity tests

- LF, CR/tqdm, split chunks, split UTF-8, final partial lines, and truncation behave as designed.
- Known HF lines produce known/unknown progress; unrelated `CPU 45%` does not become Downloading.
- Any non-empty startup output refreshes startup activity; only recognized download output changes downloading presentation.
- Regular progress/output beyond the injected inactivity interval prevents premature timeout.
- Silence after activity triggers inactivity timeout with last-activity/progress facts.
- Continuous noisy output still hits injected absolute cap.
- Stable port sentinel/common `EADDRINUSE`, import/module errors, HF/network errors, and unknown errors choose only appropriate remediation.
- Details include command source/executable/prefix, port, activity/timeout reason, progress, exit, truncation marker, stderr.

### Supervisor tests with shared temporary fixtures/seams

- Invalid-shebang command → `.launchFailed`, no retry/leaked task.
- Silent sleeping command + false health → short inactivity timeout, termination/drain, child gone.
- Progressing command survives multiple inactivity windows, then times out only after activity stops; health remains the only ready transition.
- Injected absolute cap ends a noisy unhealthy command.
- Port preflight fails before process creation; late stable sentinel short-circuits retries.
- Exit-42 fixture emits restart `1/5` through `4/5`, then terminal fifth failure with retained tail.
- Quick post-health crash consumes budget; run beyond stability window resets next exit to attempt 1.
- `stop()` during launch/readiness/backoff causes no stale restart/failure and leaves no child.
- Attempt N output/health/exit cannot mutate N+1 due to generation checks.
- Raw dev command and synthetic bundle-helper command both exercise the same spawn path; no package-specific supervisor exists.

### Python startup tests

- First socket reservation owns an available loopback port.
- Second reservation reports stable `port_in_use` before model factory invocation.

### Pure presentation tests

- starting, downloading known/unknown, restarting attempt/max, ready, and each server failure have concise row text.
- details/retry visibility is limited to server restart/failure, not secure-input/Accessibility failures.
- copied details equal displayed bounded diagnostics.

### Manual verification mapped to #4 acceptance criteria

| Acceptance criterion | Verification |
|---|---|
| Fresh clone + `make server` + `make run` works without hard-coded path; override works | Move/clone repo to an arbitrary path, run `make server`/`make app`, invoke raw executable and `make run`, and confirm `.development` command reaches Ready. Test an override wrapper and confirm `.override`. `rg '/Users/oxxxx/Code/local-dictation|compiledInRepoRoot|Contents/Resources/server' app README.md` must be empty. |
| Launch failure appears usefully in menu | Override to an executable with invalid interpreter. Confirm red concise status, command source/path, OS error/remediation, details/copy, and retry. |
| Readiness timeout appears usefully in menu | With a short test policy, use a silent sleeping wrapper and confirm inactivity timeout/child cleanup. Then use a wrapper emitting model progress longer than the inactivity window and confirm it is not killed until activity stops (or hard cap). |
| Port in use appears usefully in menu | Occupy 8471 with `python3 -m http.server`; confirm immediate port guidance and no model child. Force late race and confirm stable child sentinel maps identically. |
| Consecutive exits appear usefully in menu | Exit-42 wrapper shows attempt/max/backoff, terminates after five unstable exits, includes stderr, and recovers through Retry after fixing wrapper. |
| Recent stderr is available in UI | Open details for timeout/repeated exit, verify bounded tail/final fatal line, copy into TextEdit, and do not use Console.app. |
| README documents path/override | Follow relocated-dev and minimal override instructions exactly; verify command paths/prefix and relaunch requirement match tests. |

Additionally run cached-model normal flow Starting → optional Downloading → Ready → Listening. For #4, test the future bundle-helper command with a synthetic executable tree. Full signed package, isolated runtime import, empty-cache model download, `/Applications`, and `SMAppService` verification belong to #5.

## 6. Races, edge cases, failure behavior, and observability

- **Readiness:** `/health` HTTP 200 is the sole condition. Marker text never changes state.
- **First download:** 10-minute inactivity is refreshed by output/progress and bounded by a generous absolute cap; details report which deadline fired. #5 validates this under isolated packaged Python and empty cache.
- **Port TOCTOU/two app instances:** Swift preflight gives immediate UX; child reservation owns the port before long model creation and emits stable late-race output.
- **Existing healthy server:** never adopt it; ownership/config/parent watchdog are unknown.
- **TIME_WAIT:** use `SO_REUSEADDR`, never `SO_REUSEPORT`.
- **Exit observer:** install before `run()`; eliminate check-then-handler gap.
- **Pipe EOF:** snapshot only after readers drain; generation rejects queued old output.
- **Chunking/volume:** preserve undecoded bytes; normalize CR progress; cap UI memory at 8 KiB/50 lines; no persistent log/telemetry.
- **Bad command:** distinguish missing, non-executable, and launch failure. Invalid override does not fall through.
- **Argument order:** packaged Python flags and `-m` prefix precede server arguments. Diagnostic copy shows exact command.
- **Fast crash:** stability window, not initial health, resets restart budget.
- **Intentional stop:** generic #4 cancel/terminate is generation-safe; #1 later adds desired-running/idle reason without replacing it.
- **Realtime race:** disconnect during restart and reconnect only after supervisor running. #4 clears current boolean intent on crash; #2 later owns explicit pending/active intent semantics.
- **Retry:** terminal task is cleared before action can restart. Filesystem/path is re-resolved; config edits still require app relaunch.
- **Long menu content:** menu rows stay concise; full details are native alert + explicit clipboard action.
- **Bundle security:** #4 only recognizes an executable helper path. #5 owns runtime contents, quarantine/signing, and install verification.
- **Identity compatibility:** app/defaults/logging use `com.omcdowell.LocalDictation`; existing remap LaunchAgent remains `com.local-dictation.keyremap`.

## 7. Dependencies, conflicts, and required serial landing order

All feature refs currently equal `main`; these are ownership/dependency constraints, not existing code divergence.

1. **#4 — this plan**
   - Lands shared test target/fixtures, identity/defaults foundation, `ServerLaunchCommand`, resolver, diagnostics, health-only activity-aware supervision, generation/test seams, and server status UI.
2. **#5 — distributable `.app`**
   - Must immediately consume/extend #4’s bundle-helper command and supervisor.
   - Owns app assembly, self-contained Python/module installation under `Contents/Helpers/LocalDictationServer`, signing, `Info.plist`, packaging checks, first-download validation, and installed-app `SMAppService`.
   - Main overlap: resolver tests, `Package.swift`, `Makefile`, README, identity. It must not introduce a Resources console script, duplicate resolver, or package-specific supervisor.
3. **#2 — hold-to-talk**
   - Lands after packaged identity/menu. Owns Carbon release events, mode preference, and explicit input intent.
   - Preserves press-to-toggle as the mic-key default, adds opt-in hold-to-talk, and keeps dev hotkey/menu toggle.
   - Main overlap: `App.swift`, shared defaults, state tests. It consumes #4 server states and adds to the existing test target.
4. **#1 — idle unload**
   - Lands after #2 so idle/warm-up uses explicit pending/active intent rather than today’s ambiguous `wantsListening` boolean.
   - Adds idle config/timer and desired-running intentional stop/relaunch to #4’s supervisor, plus only missing stop-reason/generation behavior. No second broad supervisor/client rewrite.
5. **#3 — guided onboarding**
   - Lands against final packaged identity/menu after #5/#2/#1.
   - Uses `com.omcdowell.LocalDictation`, existing compatible remap label, #2 preferences, and #4 diagnostics. It does not duplicate them.

**Required serial landing order: `#4 → #5 → #2 → #1 → #3`.**

Later issues reuse `LocalDictationTests` and its process/clock/output fixtures; they do not independently add test targets or parallel fixture systems.

## 8. Incremental #4 commit / tracer-bullet sequence

Each commit remains green and reviewable.

1. **`test/core: establish identity, shared tests, and launch commands`**
   - Add `LocalDictationTests`, shared fixtures, stable `com.omcdowell.LocalDictation` defaults/log identity, `ServerLaunchCommand`, resolver/config tests and implementation.
   - Preserve `com.local-dictation.keyremap`.
   - Vertical result: relocated dev/override commands resolve; synthetic app resolves exact future helper Python command/prefix.

2. **`feat/ops: carry bounded diagnostics and startup activity`**
   - Add output collector, progress/activity parser, failure/restart types, remediation and tests.
   - Add typed app failure presentation, details/copy/retry.
   - Vertical result: an exiting fixture exposes useful stderr/command details without Console.

3. **`fix/supervisor: make command launch health-only and generation-safe`**
   - Spawn command prefix correctly; add seams, health-only readiness, inactivity + absolute startup limits, pre-run termination observation, port probe, EOF drain, termination escalation, retry stability, and generations.
   - Add lifecycle tests including activity extending first-download startup without marker readiness.
   - Vertical result: launch, timeout, restart, stale callback, and retry behavior are deterministic for both dev and synthetic bundle commands.

4. **`fix/server: reserve port before model creation`**
   - Add child socket reservation/stable fatal output and Python stdlib tests; remove/rename misleading marker.
   - Vertical result: duplicate launch fails before duplicate model loading.

5. **`docs/ops: document command discovery and in-app recovery`**
   - Add `make test`, README precedence/full helper command/override/activity timeout/troubleshooting, then execute #4 acceptance matrix.
   - Handoff to #5 explicitly names `Contents/Helpers/LocalDictationServer/bin/python3` and isolated module prefix.

## 9. Explicit assumptions and decisions

- Explicit override is authoritative, absolute after optional `~`, and has empty argument prefix.
- Future packaged command is fixed to `Contents/Helpers/LocalDictationServer/bin/python3` with `-I -B -u -m local_dictation_server.server`; there is no Resources/server console-script fallback.
- #4 recognizes but does not create the helper; #5 owns runtime/module assembly and signing.
- Application Support console scripts remain supported for local/manual installs; dev root uses `app/Package.swift` + `server/pyproject.toml` markers.
- App/defaults/log subsystem is `com.omcdowell.LocalDictation`; `com.local-dictation.keyremap` remains unchanged.
- Existing servers are never adopted.
- `/health` 200 is the sole readiness condition.
- Startup timeout is activity-aware: proposed 600 seconds inactivity plus 60-minute hard cap, both tested/injectable and validated by #5 under first download.
- Restart policy remains five unstable exits, existing capped exponential backoff, and 60-second stability threshold.
- Recent stderr is non-persistent 8 KiB/50 lines, visible/copyable in app.
- #4 performs only narrow crash cleanup using current boolean intent. #2 owns the press-to-toggle default, opt-in hold-to-talk, Carbon release, mic mode, and explicit pending/active intent; #1 builds idle desired-running behavior on that.
- No new third-party Swift/Python dependency is required.

### Genuinely unresolved questions

None blocking #4. #5 must verify that its self-contained Python layout makes the fixed isolated `-m local_dictation_server.server` invocation import successfully and may tune the shared, tested startup timeout constants based on an empty-cache package run; it must not change the command contract or readiness source without cross-issue reconciliation.
