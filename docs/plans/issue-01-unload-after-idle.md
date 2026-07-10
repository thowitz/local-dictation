# Issue #1 implementation plan — unload ASR server after idle

## Scope and integration baseline

Implement only issue #1’s idle-unload lifecycle. This issue lands **after #4, #5, and #2** and must extend their shared contracts rather than recreating them:

- **#4** already owns the first Swift test target and shared fixtures, portable server resolution, `ServerLaunchCommand`, structured diagnostics, health-only readiness, output/activity-aware startup timeout behavior, and generation-safe process supervision seams.
- **#5** already owns the assembled/signed `.app`, self-contained Python runtime, `Info.plist`, installed-app `SMAppService` behavior, and the packaged resolver source.
- **#2** already owns Carbon press/release handling, persisted mic-key mode, and explicit pending/active input intent. The default mic-key mode remains press-to-toggle for compatibility; hold-to-talk is opt-in, and the development hotkey and menu action remain toggle.

Issue #1 adds a configurable controller-owned idle deadline, targeted intentional-stop/desired-running behavior to #4’s supervisor, persistent WebSocket teardown, and cold relaunch through #2’s intent model. It does **not** introduce another process abstraction, resolver, diagnostics system, test target, broad supervisor rewrite, or broad WebSocket client rewrite.

Recommended serial landing order for the full issue set is:

> **#4 → #5 → #2 → #1 → #3**

## 1. Current state and reconciled code paths

### Current repository state before prerequisite issues land

- `app/Sources/LocalDictation/AppConfig.swift`
  - `AppConfig.load()` reads `~/Library/Application Support/LocalDictation/config.json` once at launch.
  - Current fields are `serverExecutable`, `port`, and `model`; there is no idle setting.
  - Current synthesized `Codable` would fail an old config if a new required field were added without `decodeIfPresent` defaults.
  - Current `compiledInRepoRoot` and `resolvedServerExecutable` are developer-machine-specific. **#4, not #1, replaces this with portable resolution.**

- `app/Sources/LocalDictation/App.swift`
  - `DictationController.bootstrap()` eagerly starts `ServerSupervisor`.
  - Loaded-but-inactive is `DictationState.ready`; `DictationState.idle` means the server is stopped.
  - Current `wantsListening` latches a cold start through supervisor launch, `/health`, WebSocket connection, and `beginListening()`.
  - `stopDictation()` enters `.flushing`; `handleDone(_:)` returns to `.ready`. `cancelDictation()` immediately clears/discards and returns to `.ready` when the runtime is healthy.
  - `handleServerState(.running)` opens the persistent WebSocket. `handleConnectionState(.connected)` enters `.ready` and invokes `beginListening()` if input is still requested.
  - `AppDelegate.quitApp()` currently depends mainly on the Python parent watchdog rather than an explicit controller shutdown.

- `app/Sources/LocalDictation/ServerSupervisor.swift`
  - Current readiness accepts either `VOXMLX_READY` or `/health`; **#4 must remove ready-marker readiness so `/health` HTTP 200 is the only readiness condition before #1 lands.**
  - Current `stoppingIntentionally` is a mutable global Boolean. `stop()` cancels the task, calls `Process.terminate()`, clears shared process state immediately, and emits `.stopped` without reaping.
  - An immediate stop/start can let an old task clear a new task or let a new health probe mistake the terminating child for an unrelated process on the port.
  - **#4 owns the foundational repair:** generation-safe child/task identity, deterministic process/health/clock seams, structured failure diagnostics, and output/activity-aware startup timeout behavior.
  - **#1 only adds idle-specific desired-running and stop-reason semantics missing from that foundation.**

- `app/Sources/LocalDictation/RealtimeClient.swift`
  - `disconnect()` disables automatic reconnect, cancels the reconnect task, and closes the persistent socket.
  - Delayed reconnect work currently relies largely on `shouldAutoReconnect`. If #4/#2 have not already added an epoch, #1 needs only a narrow stale-reconnect token check around explicit idle disconnect/reconnect—not a new client architecture.

- `server/src/local_dictation_server/server.py`
  - `/health` is available after model load and app construction.
  - The server creates one `StreamingSession` per WebSocket and resets it on disconnect.
  - Each managed launch receives `--parent-pid`; `server/src/local_dictation_server/_watchdog.py` exits if the app dies.
  - No Python server change is required for issue #1.

- `app/Package.swift`
  - The repository currently has no test target. **#4 owns adding the single shared Swift test target and common fixtures. Later issues, including #1, reuse it.**

### Required post-#4/#5 launch contract

Issue #1 must be command-source agnostic and relaunch exactly the `ServerLaunchCommand` resolved by the shared resolver from #4/#5:

```swift
struct ServerLaunchCommand {
    let executableURL: URL
    let argumentPrefix: [String]
    let source: ServerLaunchSource
}
```

The packaged source created by #5 is:

```text
executableURL: <App>.app/Contents/Helpers/LocalDictationServer/bin/python3
argumentPrefix: [-I, -B, -u, -m, local_dictation_server.server]
source: packaged helper
```

Runtime arguments such as `--port`, `--model`, and `--parent-pid` are appended after `argumentPrefix` by the shared supervisor. There is **no** `Contents/Resources/server` console-script contract. Development and explicit-override sources use the same `ServerLaunchCommand` type.

### Required identity baseline

By #1’s landing point:

- stable app bundle ID and defaults suite: **`com.omcdowell.LocalDictation`**;
- #2’s persisted mic-mode preference and all other defaults use that stable suite;
- #5’s packaged `Info.plist`, signing identity, and `SMAppService.mainApp` behavior use that bundle identity;
- the existing LaunchAgent label **`com.local-dictation.keyremap` remains unchanged** for compatibility.

Issue #1 must not rename the LaunchAgent or introduce another defaults suite.

## 2. Chosen design and lifecycle changes

### Configuration contract

Extend the post-#4 `AppConfig` with `idleUnloadMinutes: Double`:

- omitted: effective default `10.0` minutes;
- positive: unload deadline, with fractional values accepted for testing;
- `0`: never unload and preserve the always-resident behavior;
- negative: invalid; emit a structured configuration diagnostic/log and use 10 minutes rather than silently disabling unload;
- read at app launch only; changing `config.json` requires relaunch.

Use the backward-compatible decoding pattern established by #4. Do not replace #4’s config diagnostics or resolver configuration. Add the field to its existing explicit `decodeIfPresent`/validation path and preserve all launch-command/path overrides.

### Timer ownership

Add a small `@MainActor` `IdleUnloadScheduler`, owned by `DictationController`.

The timer belongs above `ServerSupervisor` because the controller and #2’s input-intent model know whether a request is pending, listening is active, or final flush is active. The scheduler contains only:

- optional timeout (`nil` when configured as `0`);
- one cancellable task;
- a monotonically increasing timer generation;
- the shared/injected clock or sleeper fixture from #4;
- `reset`, `ensureArmed`, `cancel`, and `isArmed` operations.

A completion validates both cancellation and generation before invoking its action. A stale completion queued before a reset cannot unload a newly active session.

Timer policy:

1. Arm once when initial bootstrap reaches health-ready **and** the persistent WebSocket is connected, provided #2 reports no pending/active input intent.
2. Cancel immediately when #2 changes input intent to pending or active. A cold hold-to-talk key-down therefore protects the entire warm-up.
3. Never arm while listening or flushing.
4. Reset to a full interval after normal `.done`, Esc cancel, hold-to-talk key-up completion, or an aborted active session that returns to an inactive runtime.
5. A transient idle WebSocket reconnect does not count as activity and does not extend an existing deadline.
6. If a spontaneous server restart is underway with no pending/active input intent, the existing idle deadline may intentionally stop that restart when it expires.
7. Cancel when the runtime is intentionally stopped, terminally failed with no child, or the app shuts down.

At timeout, re-check on the main actor that #2 reports neither pending nor active input intent and that the app is not listening/flushing. If the guard fails, do nothing; the eventual session-end path creates the next full deadline.

### Interaction with #2 input intent

Do not retain or reintroduce a parallel issue-#1-only `wantsListening` flag after #2. Use #2’s explicit intent as the source of truth.

Expected behavior by input source:

- **Mic key in default toggle mode:** each key-down follows #2’s persisted toggle intent; key-up is ignored.
- **Mic key in opt-in hold-to-talk mode:** key-down sets pending intent and starts/warms the runtime; key-up clears pending intent or ends active listening through #2’s existing path.
- **Brief hold released before readiness:** #2 clears pending intent. Warm-up continues; when health and WebSocket readiness eventually arrive, #1 must not begin listening. The loaded runtime becomes inactive and receives a fresh idle deadline; do not immediately kill/restart it and do not leave the app stuck in listening/flushing.
- **Development hotkey and menu:** remain toggle regardless of mic-key mode.

Issue #1 subscribes to/queries the intent model; it does not own Carbon key-up events, mode persistence, or preference menu items.

### App states and cold-start path

Keep `.idle` as fully stopped and `.ready` as resident/connected. Add a short-lived `.unloading` app state only if the post-#2 state enum has no equivalent.

```text
bootstrap
  -> #4/#5 starting or downloading (activity-aware timeout)
  -> /health 200 (only readiness signal)
  -> persistent WebSocket connected
  -> ready; arm idle deadline

ready --idle deadline and no input intent--> unloading
  -> explicit WebSocket disconnect
  -> supervisor.stop(reason: .idleTimeout)
  -> child confirmed exited
  -> idle

idle/unloading --#2 pending input intent--> warming/starting
  -> supervisor desiredRunning = true
  -> resolve/reuse current ServerLaunchCommand
  -> wait for prior intentional child exit if necessary
  -> launch packaged or development command
  -> /health 200
  -> connect WebSocket
  -> if #2 intent is still pending, existing begin-listening path
  -> if intent was cleared, ready and arm a fresh idle deadline

listening --stop/key-up--> flushing --done--> ready; reset deadline
listening/flushing --Esc--> ready; reset deadline
```

Use existing `.starting` or its post-#4 equivalent with user-facing “Warming up…” copy for a cold request. Preserve #4’s structured downloading/error details. Do not add another diagnostic state model.

A start arriving during `.unloading` changes the UI to warming immediately and sets `desiredRunning = true`. It must queue behind the exact intentionally terminating child rather than probing/spawning against that child’s port.

### Targeted supervisor extension on top of #4

Use #4’s generation-safe process record, launch command, health probe, output tracking, startup timeout policy, process driver, diagnostics, and test fixtures unchanged.

Add only the idle lifecycle concepts that #4 does not own:

- `ServerSupervisor.StopReason`, at minimum `.idleTimeout` and `.applicationQuit`;
- `desiredRunning`, controlled by idempotent start/stop requests;
- per-run intentional-stop metadata associated with #4’s existing run generation;
- queued relaunch after an intentional child is fully reaped.

Rules:

1. `start()` sets `desiredRunning = true`.
2. `stop(reason:)` sets `desiredRunning = false` and records the reason/intent on the current run **before** cancelling readiness/backoff or signaling the child.
3. Unexpected exit while desired-running is true retains #4’s restart/backoff/structured-diagnostic behavior.
4. Intentional exit never increments consecutive failure counts and never emits a spurious restart loop.
5. If `start()` arrives while an intentionally stopped child is exiting, change desired-running back to true, show warming, and wait for #4’s existing run-reap completion. Then launch exactly once with the same resolved `ServerLaunchCommand` contract.
6. Old-run completion remains protected by #4’s generation identity and cannot clear or transition a newer run.
7. Emit fully stopped only once the child is confirmed gone and desired-running is still false.
8. Preserve `--parent-pid` on every relaunch.
9. Preserve #4/#5’s output/activity-aware timeout. A first packaged model download may legitimately take a long time while producing activity; issue #1 must not add a fixed timer or `VOXMLX_READY` shortcut around it.

Do not add a second `ServerProcess.swift`, alternate process launcher, alternate health checker, or duplicate generation system.

### Persistent WebSocket teardown/reconnect

Idle unload order is fixed:

1. transition to `.unloading` (or post-#2 equivalent);
2. call the existing explicit `RealtimeClient.disconnect()` so automatic reconnect is disabled and the persistent session closes;
3. call `ServerSupervisor.stop(reason: .idleTimeout)`.

Reuse the current client. If its post-#4/#2 implementation still allows reconnect work scheduled before explicit disconnect to execute after a later connect, add only a lightweight connection epoch/token in `RealtimeClient.swift`:

- increment on explicit disconnect/connect cycles;
- capture it in delayed reconnect work;
- require current epoch and task identity immediately before reconnecting;
- avoid duplicate disconnected publication for an already disconnected client.

Do not introduce a new WebSocket transport layer or redesign framing/backoff. On cold start, call `connect()` only after #4 publishes health-ready/running. Audio begins only after the socket is connected and #2 input intent is still pending/active.

### App shutdown

Add or extend an idempotent `DictationController.shutdown()`:

- cancel idle scheduling and clear pending/active intent through #2’s sanctioned shutdown path;
- unregister Esc, stop audio, discard any buffered text, and hide the indicator;
- explicitly disconnect the persistent WebSocket;
- call `supervisor.stop(reason: .applicationQuit)`.

Wire Quit and `applicationWillTerminate` without changing #5’s installed-app/`SMAppService` ownership. The parent-PID watchdog remains a backstop if the app exits before graceful reaping completes.

## 3. Ordered file-by-file changes

### Prerequisite baseline to verify, not reimplement in #1

Before changing #1, confirm the landing branch contains:

- **From #4**
  - the shared `LocalDictationTests` Swift test target and shared clock/process/health/diagnostic fixtures;
  - portable resolver and `ServerLaunchCommand(executableURL, argumentPrefix, source)`;
  - structured supervisor/config diagnostics;
  - `/health`-200-only readiness;
  - generation-safe process supervision;
  - output/activity-aware startup timeout.
- **From #5**
  - actual `.app` assembly and signed/self-contained helper runtime;
  - packaged Python at `Contents/Helpers/LocalDictationServer/bin/python3`;
  - packaged command prefix `[-I, -B, -u, -m, local_dictation_server.server]`;
  - stable `com.omcdowell.LocalDictation` `Info.plist` identity and installed-app `SMAppService` behavior.
- **From #2**
  - Carbon key press/release handling;
  - default press-to-toggle mic mode, opt-in hold-to-talk mode, and persisted mode preference;
  - toggle-only dev hotkey/menu behavior;
  - explicit pending/active input intent and brief-hold cancellation.

If one of these is absent, rebase/land the owning issue; do not absorb it into #1.

### Issue #1 changes

1. **`app/Sources/LocalDictation/AppConfig.swift`**
   - Add `idleUnloadMinutes` and effective optional duration using #4’s existing decoding/validation/diagnostic conventions.
   - Default to 10, map exactly zero to disabled, and diagnose/fallback on negatives.
   - Preserve all #4 resolver fields and #2 preferences; do not alter launch resolution or defaults suite.

2. **New `app/Sources/LocalDictation/IdleUnloadScheduler.swift`**
   - Implement the one-shot main-actor scheduler with generation-based cancellation.
   - Consume #4’s shared clock/sleeper abstraction rather than defining an incompatible second one.
   - Keep it policy-free: the controller supplies timeout eligibility/action.

3. **`app/Sources/LocalDictation/ServerSupervisor.swift`**
   - Extend #4’s supervisor with `StopReason`, desired-running intent, and intentional-stop metadata tied to the existing run generation.
   - Queue one relaunch when desired-running returns true during teardown.
   - Reuse #4’s `ServerLaunchCommand`, process handle, reaping, backoff, output activity, timeout, diagnostics, and test seams.
   - Keep `/health` 200 as the sole readiness path; do not inspect `VOXMLX_READY`.

4. **`app/Sources/LocalDictation/RealtimeClient.swift`**
   - Prefer no structural change beyond using existing explicit disconnect/connect.
   - If required by tests, add the minimal reconnect epoch guard described above; preserve the existing persistent-client implementation and backoff.

5. **`app/Sources/LocalDictation/App.swift`**
   - Integrate `IdleUnloadScheduler` with #2’s pending/active intent transitions.
   - Arm after initial health + socket readiness; cancel on pending/active intent; reset on all completed/cancelled session paths.
   - Add `.unloading` only if no equivalent exists after #2/#4; add warming copy without replacing #4 diagnostics.
   - Timeout handler must order WebSocket disconnect before supervisor intentional stop.
   - Cold start must set supervisor desired-running, reuse the current resolved command, wait for health, connect the socket, and begin only if #2 intent remains.
   - Add/extend idempotent shutdown for `.applicationQuit`.
   - Do not modify Carbon press/release ownership, mic mode preference, the default toggle mode, or hold-to-talk behavior.

6. **Existing shared tests under `app/Tests/LocalDictationTests/`**
   - Extend #4’s config tests for idle default/custom/zero/negative behavior.
   - Add `IdleUnloadSchedulerTests.swift` using #4’s controlled clock fixture.
   - Extend #4’s `ServerSupervisorTests` for stop reason, no restart after idle stop, and one queued relaunch during teardown.
   - Add/extend controller lifecycle tests using #2’s fake intent model and #4’s fake supervisor/realtime/clock fixtures.
   - Add a narrow reconnect-epoch test only if `RealtimeClient` needed that guard.
   - Reuse shared fixture files; do not add another test target or parallel process/clock doubles.

7. **`README.md`**
   - Add a brief Configuration subsection for `idleUnloadMinutes` at the existing Application Support config path.
   - Document default 10, positive/fractional minutes, `0` disabling unload, and relaunch required after config edits.
   - Explain Ready → Server stopped after idle → Warming up on the next trigger.
   - Keep #4’s server-resolution/diagnostic docs and #5’s packaging/install docs intact.

### Files not owned by #1

- **`app/Package.swift`**: #4 already added the shared test target; #1 changes it only if a new source/test path genuinely requires manifest registration, which normal SwiftPM layout does not.
- **Packaging scripts/Makefile/`Info.plist`/signing**: #5 owns these.
- **Carbon/mic-mode preference code**: #2 owns it.
- **Onboarding/menu checklist**: #3 owns it after #1.
- **`server/src/**`, `server/pyproject.toml`, `PLAN.md`**: no expected #1 changes.
- **LaunchAgent label**: retain `com.local-dictation.keyremap`.

## 4. Tests and manual verification mapped to acceptance criteria

| Acceptance criterion | Automated verification in shared target | Manual/on-target verification |
|---|---|---|
| Server exits and RSS disappears after idle, never during listening/flushing | Scheduler tests cover arming/reset/cancel/stale generation. Controller tests use #2 intent fixtures to prove no unload while pending/active/flushing and verify disconnect-before-stop. #4 supervisor fixtures prove intentional child reaping. | Set `idleUnloadMinutes` to `0.05`, launch packaged app to Ready, record child PID/RSS, wait >3 seconds, and verify `kill -0` fails, `ps -p <pid> -o rss=` is empty, `/health` is down, and no replacement appears. Repeat with pending hold, active listening, and flushing; only unload after session end plus a fresh full interval. |
| Next start relaunches, visibly warms, then listens | Lifecycle test drives `.idle/.unloading -> warming`, desired-running true, queued relaunch, health-ready event, socket connect, and conditional begin based on #2 intent. Test a brief hold release before readiness and assert no listening starts. | After unload, hold F13. Confirm “Warming up…” immediately, one new packaged-helper PID, then `/health` 200, WebSocket connection, indicator/audio, and text. Release before readiness and confirm no stuck listening/flushing; runtime becomes Ready and later idles out. Verify dev hotkey/menu still toggle. |
| Duration configurable; default about 10; `0` disables | Extend #4 config tests for omitted/default, positive/fractional, zero, negative diagnostic/fallback, and preservation of resolver fields. Scheduler test proves zero creates no task. | Verify omitted key logs/evaluates to 10. Test short positive value. Set `0`, relaunch, wait beyond the prior timeout, and verify the same process remains resident and next dictation has no cold load. |
| Watchdog and intentional stop do not restart spuriously | Extend #4 supervisor tests: idle/app-quit stop marks current generation intentional; no backoff/failure increment; start during reap produces one replacement; stale old completion cannot affect it; launch command still appends `--parent-pid`. | Observe logs/processes across unload for longer than one backoff window: no replacement. Trigger once and confirm exactly one replacement using the packaged command. Kill a healthy child unexpectedly and confirm #4 restart still works. Quit the app and confirm direct stop/watchdog leaves no child. |
| README documents key | Documentation review/grep in existing CI if available. | Follow the JSON example from a clean config and confirm behavior. |

Run before landing:

```bash
cd app && swift test
cd app && swift build -c release
make lint
make smoke              # model already cached
make package            # #5 packaging verification path
```

Also run #4/#5’s packaged-app verification so relaunch uses:

```text
<App>.app/Contents/Helpers/LocalDictationServer/bin/python3
  -I -B -u -m local_dictation_server.server ...
```

and not a repository `.venv` or Resources console script.

Additional race checks:

1. Trigger at the idle deadline. Either active intent cancels the timer first, or unload wins and desired-running queues behind teardown; the result must be listening if intent remains, with no port-in-use error.
2. Press and release the hold key during `.unloading`/warming. No listening may begin after release, no duplicate child may launch, and the app must settle to Ready then idle normally.
3. Complete final transcript near an old deadline. The stale timer generation must not unload the newly reset inactive interval.
4. Sleep/wake across a deadline. A due continuous-clock timer may unload on wake only when #2 reports no pending/active intent and the app is not flushing.
5. Perform the same lifecycle from the installed `.app` and after Launch at Login; `SMAppService` must continue targeting #5’s installed app identity.

## 5. Races, edge cases, failure behavior, and observability

### Races and edge cases

- **Timer vs #2 intent change:** both reconcile on the main actor. Intent transition cancels/increments the timer generation before asynchronous warm-up. The timeout re-checks intent.
- **Brief hold during cold warm-up:** release clears pending intent through #2. Health/socket callbacks must query current intent, not a captured key-down Boolean.
- **Old timer vs new session-end deadline:** generation invalidation prevents an already-resumed old sleeper from firing.
- **Timeout during flush:** no timer is armed; the callback guard also rejects flushing defensively.
- **Start during intentional teardown:** #1 changes only desired-running on #4’s active generation. Reaping completes before one replacement command launches.
- **Old child owns the port:** do not health-probe/spawn the replacement until #4 confirms that child exited. External port ownership still follows #4 structured diagnostics.
- **Stale process callback:** #4’s generation-safe callback rules remain authoritative; #1’s stop reason is metadata on that generation.
- **Stale WebSocket reconnect:** explicit disconnect disables reconnect. If necessary, a small epoch invalidates pre-unload delayed work permanently.
- **Initial packaged model download:** no idle deadline exists before health + socket readiness. #4/#5 output/activity-aware startup timeout remains in force; no fixed idle timer or ready-marker shortcut can kill an active first download.
- **Health semantics:** stdout may remain useful diagnostic/activity input, but only `/health` HTTP 200 transitions supervisor readiness.
- **Config zero:** disabled, not immediate unload.
- **Identity:** all defaults/preferences remain under `com.omcdowell.LocalDictation`; key-remap compatibility label remains `com.local-dictation.keyremap`.

### Failure behavior

- If intentional termination fails, use #4’s existing termination escalation/reaping and structured diagnostics. Do not add a second kill timeout in #1.
- A queued start does not spawn until #4 confirms old-process exit. If exit cannot be confirmed, surface #4’s failure diagnostic rather than colliding on the port.
- Cold launch/download/readiness failures retain #4’s structured UI detail. Clear/resolve #2 pending intent according to #2’s failure rules; never begin recording from a stale intent after recovery.
- Idle disconnect itself cannot auto-reconnect. An unexpected socket loss while resident keeps existing reconnect behavior and does not reset idle activity.
- No live utterance is intentionally discarded because pending, active, and flushing states are excluded from unload eligibility.

### Observability

Use #4’s structured diagnostics/logging channel; do not invent a parallel issue-#1 diagnostics model. Add events/context for:

- effective idle policy (`disabled` or minutes);
- idle deadline arm/reset/cancel/fire and timer generation;
- timeout rejected because input is pending/active or flush is in progress;
- stop reason (`idleTimeout` or `applicationQuit`) and #4 run generation/PID;
- desired-running changed during teardown and queued relaunch;
- intentional versus unexpected exit;
- explicit WebSocket disconnect/connect epoch and stale reconnect rejection, if the epoch is needed;
- launch-command source on relaunch, using #4’s existing `ServerLaunchCommand.source` diagnostics.

User-visible status should preserve #4’s detailed start/download/error status and add only the lifecycle copy needed here: Ready → Unloading/Server stopping → Idle/Server stopped → Warming up → Ready/Listening.

## 6. Dependencies, conflicts, and required landing order

### #4 — land first

Owns:

- first shared Swift test target and fixtures;
- portable server resolver;
- `ServerLaunchCommand(executableURL, argumentPrefix, source)`;
- structured diagnostics;
- `/health`-200-only readiness;
- generation-safe process supervision and deterministic seams;
- output/activity-aware startup timeout.

Conflict surface with #1: `AppConfig.swift`, `ServerSupervisor.swift`, `App.swift`, tests, README. #1 must rebase onto #4 and extend its types. It must not merge an independent supervisor rewrite.

### #5 — land second

Consumes/extends #4’s resolver and supervisor. Owns:

- actual `.app` assembly;
- self-contained Python runtime;
- packaged helper at `Contents/Helpers/LocalDictationServer/bin/python3` with `[-I,-B,-u,-m,local_dictation_server.server]`;
- signing, `Info.plist`, packaging verification;
- stable `com.omcdowell.LocalDictation` packaged identity;
- installed-app `SMAppService` behavior.

Conflict surface with #1: launch resolution assumptions, Package/README, shutdown behavior in installed app. #1 consumes the packaged command and must not create a Resources/server console script or duplicate packaging logic.

### #2 — land third

Owns:

- Carbon press and release events;
- mic-key mode persistence and menu preference;
- default press-to-toggle mic-key mode with opt-in hold-to-talk;
- toggle-only development hotkey/menu behavior;
- explicit pending/active input intent and brief-hold warm-up cancellation.

Conflict surface with #1: `App.swift`, preferences/config, lifecycle tests. #1 schedules/unloads based on #2 intent and must not add another pending-listening Boolean or alter input mode ownership.

### #1 — land fourth

Owns only:

- idle duration config;
- idle scheduler;
- idle-specific desired-running/intentional stop reason layered onto #4;
- persistent socket teardown before idle stop;
- cold relaunch integration through #2 intent and #4/#5 launch command;
- idle docs/tests in the shared test target.

### #3 — land fifth

Lands against the packaged identity and final menu. It uses `com.omcdowell.LocalDictation`, reuses #4 diagnostics and #2 preferences, and must not duplicate either. It retains the compatibility LaunchAgent label. Rebase its menu/onboarding work after #1’s final status states.

### Required serial order

> **#4 → #5 → #2 → #1 → #3**

Parallel development is possible only in rebased worktrees; merge in this order and rerun shared lifecycle/package tests after each rebase.

## 7. Incremental commit / tracer-bullet sequence for #1

Every commit uses the shared #4 test target/fixtures and remains green; develop each red → green → refactor.

1. **`feat(config): add idle unload duration to shared app config`**
   - Extend #4 decoding/validation/diagnostics and tests for default, custom, zero, negative, and resolver-field preservation.

2. **`feat(lifecycle): add controller-owned idle scheduler`**
   - Add `IdleUnloadScheduler` using #4’s clock seam.
   - Integrate with #2 pending/active intent and session completion.
   - Tests establish Ready → guarded timeout and prove pending/listening/flushing exclusion.

3. **`feat(supervisor): add idle stop reason and desired-running relaunch`**
   - Extend #4’s supervisor generation with stop reason/desired-running only.
   - Tests prove no intentional restart loop and exactly one queued relaunch during teardown using the same `ServerLaunchCommand`.

4. **`feat(runtime): disconnect persistent socket and cold-start on demand`**
   - Order unload as state → socket disconnect → supervisor stop.
   - Add minimal reconnect epoch only if a failing shared test demonstrates it is needed.
   - Complete the tracer: resident Ready → idle unload → packaged command warm-up → health 200 → socket connect → listen only while #2 intent remains.

5. **`docs: document idle unload and verify packaged shutdown`**
   - Add idempotent app shutdown stop reason, README config/status text, structured log context, full shared tests, smoke, package verification, RSS checks, and Launch-at-Login verification.

Do not include #3 onboarding changes or modify ownership established by #4/#5/#2.

## 8. Explicit assumptions and decisions

- Issue #1 is implemented only after #4, #5, and #2 have landed.
- The app still eagerly loads the model on launch. Fully on-demand initial launch is outside #1.
- Idle means no pending or active input intent and no final flush; idle socket reconnection is not activity.
- The first deadline begins only after `/health` 200 and persistent WebSocket connection.
- `/health` HTTP 200 is the only readiness condition. `VOXMLX_READY` may be logged as output but cannot drive readiness.
- First model download uses #4/#5’s output/activity-aware timeout, not a brittle fixed timeout or stdout marker.
- `idleUnloadMinutes` is launch-time config; no live settings UI/file watcher is added.
- Fractional minutes are allowed; `0` disables; negative values diagnose and fall back to 10.
- The persistent WebSocket stays open while resident and closes before intentional process stop.
- Relaunch is agnostic to source and reuses #4’s resolved command. The packaged command is exactly `Contents/Helpers/LocalDictationServer/bin/python3` plus `-I -B -u -m local_dictation_server.server` before runtime arguments.
- No `Resources/server` console-script contract is introduced.
- Stable bundle/defaults identity is `com.omcdowell.LocalDictation`; `com.local-dictation.keyremap` remains the LaunchAgent label.
- Mic-key default remains press-to-toggle for compatibility; hold-to-talk is opt-in, and the dev hotkey/menu remain toggle. #1 does not own these preferences/events.
- Existing audio, insertion, terminal buffering, Esc semantics, server wire protocol, and Python watchdog remain unchanged.
- #1 reuses the single shared Swift test target and shared fixtures from #4.

### Genuinely unresolved questions

None. The reconciled cross-issue contract resolves ownership, order, identity, launch layout, readiness, and input-intent semantics sufficiently for implementation.
