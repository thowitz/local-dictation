# Issue #2 implementation plan — Hold-to-talk mic key

Issue: `omcdowell/local-dictation#2` — **Hold-to-talk mic key**
Scope: Swift menu-bar app input/lifecycle behavior only; no ASR/model changes.

## 1. Current state and code paths

### Trigger and state path

- `app/Sources/LocalDictation/App.swift`
  - `DictationState` is the user-visible state machine: `.idle`, `.starting`, `.downloading`, `.ready`, `.listening`, `.flushing`, `.error`.
  - `AppDelegate.applicationDidFinishLaunching(_:)` registers two permanent `CarbonHotKey`s:
    - `toggleHotKey`: Option-Command-D, the development shortcut.
    - `f13HotKey`: unmodified F13, produced by the mic-key remap.
    - Both currently share the same `onPressed` closure and call `DictationController.toggleDictation()`.
  - `CarbonHotKey.ensureSharedHandler()` subscribes only to `kEventHotKeyPressed`. The SDK exposes the matching `kEventHotKeyReleased`; the current callback does not inspect `GetEventKind`, has no release callback, and has no held-key/repeat latch.
  - `DictationController.toggleDictation()` starts from `.ready`/`.idle`/`.error` and calls `stopDictation()` only from `.listening`. `stopDictation()` performs the required existing final path: `.flushing` -> indicator processing -> `AudioCapture.stop()` -> `RealtimeClient.commitFinal()`.
  - `wantsListening` is the current deferred-start flag. `startDictation()` sets it from `.idle`/`.error`, but presses received while `.starting` or `.downloading` are discarded. `handleServerState(.running)` and `handleConnectionState(.connected)` consume it after readiness. There is no release edge that can revoke a deferred request.
  - `beginListening()` rechecks Secure Input and Accessibility, clears server state, begins the `TextInserter` session, starts audio, registers Esc, shows the indicator, and enters `.listening`.
  - `cancelDictation()` accepts Esc in both `.listening` and `.flushing`; it immediately unregisters Esc, stops audio, discards terminal-buffer text, hides the indicator, sends `clearBuffer()`, and returns to `.ready` or `.starting` without waiting for final output.
  - `handleDelta(_:)` currently accepts transcript text regardless of state. `handleDone(_:)` only completes a session when state is `.flushing`. Thus a commit already being finalized can emit deltas after Esc and those deltas can still be inserted; a rapid new session can also receive stale uncorrelated output.
  - `AppPrefs` currently contains only first-run and sound keys, and the initial code uses `UserDefaults.standard`. By the time #2 lands, #5 establishes the stable app identity/defaults suite `com.omcdowell.LocalDictation`; #2 must add its mic-mode key to that shared suite rather than deriving a new domain or expanding the server-oriented `AppConfig` JSON.

### Supporting paths

- `app/Sources/LocalDictation/RealtimeClient.swift`
  - `Callbacks` exposes delta, done, connection, and error callbacks, but ignores the existing `input_audio_buffer.cleared` server event.
  - `sendJSON(_:)`, `commitFinal()`, and `clearBuffer()` return no enqueue result, so the controller cannot immediately recover if a release/cancel frame is dropped because the socket is already disconnected.
- `server/src/local_dictation_server/server.py`
  - `create_app(...).realtime` handles one WebSocket message at a time. A final commit emits trailing deltas and `.done`, then resets the `StreamingSession`. A clear resets it and replies with `input_audio_buffer.cleared`.
  - That serialized ordering supplies a client-side cancellation barrier: once the clear acknowledgement arrives, all output from earlier commit/append messages has already been sent. No server protocol change is required if cancellation is the only source of clear requests.
- `app/Sources/LocalDictation/AudioCapture.swift`
  - `stop()` synchronously removes the tap and drops pending sub-chunk audio. A very short session can therefore commit no audio, but the server still emits `.done`; this should use the same flush path as toggle mode.
- `app/Sources/LocalDictation/TextInserter.swift`
  - Stream mode inserts deltas immediately. Buffer mode accumulates until `flush()` and `discard()` already provides the required Esc behavior.
- `app/Sources/LocalDictation/IndicatorPanel.swift` and `IndicatorSounds.swift`
  - Existing listening/processing/hide and start/stop sound paths are sufficient; hold mode should call them through `DictationController`, not duplicate them.
- `app/Sources/LocalDictation/MicKeyManager.swift`
  - Remaps Consumer usage `0xC000000CF` to F13 and defines `f13KeyCode = 105`. It does not own key events. Some comments currently describe F13 as toggle-only.
- `app/Sources/LocalDictation/ServerSupervisor.swift`
  - In the initial code, startup/download callbacks drive the deferred-start race and readiness can be inferred from `sawReadyMarker` or health. Prerequisite #4 replaces that with generation-safe supervision and **only HTTP `/health` 200** as server readiness. #2 consumes the resulting state; it does not alter supervisor readiness, launch-command resolution, stop reasons, or diagnostics.
- `app/Package.swift`
  - The initial commit contains only the executable target. Prerequisite #4 owns creation of the first shared Swift test target and common fixtures/test seams. #2 only adds tests to that existing target.
- `README.md` and `PLAN.md`
  - Both describe the mic key as toggle-only; `PLAN.md` also lists hold-to-talk as out of scope.

### Required integration baseline before #2

This plan is implemented after #4 and #5, not directly against the initial commit:

- **#4** owns portable server resolution, structured launch/readiness/runtime diagnostics, health-only readiness, generation-safe process supervision and its test seams, plus the general `ServerLaunchCommand` value (`executableURL`, `argumentPrefix`, `source`). Its packaged candidate contract is exactly:
  - executable: `Contents/Helpers/LocalDictationServer/bin/python3`
  - argument prefix: `["-I", "-B", "-u", "-m", "local_dictation_server.server"]`
  - there is no `Resources/server` console-script contract.
- **#5** consumes and extends that resolver/supervisor, materializes the helper command in an assembled `.app`, and owns the self-contained Python runtime, signing, `Info.plist`, packaging verification, and installed-app `SMAppService` behavior. It establishes bundle ID/defaults suite `com.omcdowell.LocalDictation`.
- #4/#5 also establish output/activity-aware first-model-download timeout behavior. #2 must wait on their supervisor state and WebSocket connection; it must not read stdout, restore `VOXMLX_READY` as a readiness condition, or add its own timeout/restart policy.

## 2. Chosen design and lifecycle changes

### Input mode and trigger scope

Add a string-backed `MicKeyMode` with two values:

- `.holdToTalk` — opt-in press-and-hold behavior.
- `.toggle` — default when no preference exists, preserving current F13 press-to-start/press-to-stop behavior.

Persist the selected raw value in the shared `com.omcdowell.LocalDictation` defaults suite established by #5. Present a native **Mic Key Mode** submenu with radio/checkmark items **Hold to Talk** and **Press to Toggle**. Do not introduce a second suite or package-specific key.

The preference applies only to F13/the remapped mic key:

- F13 in hold mode: accepted down requests start; matching up requests commit/flush.
- F13 in toggle mode: accepted down calls the existing toggle path; up is a no-op.
- Option-Command-D remains an always-toggle development shortcut in both modes.
- The status-menu Start/Stop item also remains an always-toggle/manual control.

Latch the configured mode on F13 down and use that latched value on up. A preference change while F13 is physically held applies to the next gesture and cannot strand the current hold session.

### Carbon edges and repeat handling

Extend `CarbonHotKey` rather than introducing an event tap:

1. Install the shared handler for both `kEventHotKeyPressed` and `kEventHotKeyReleased`.
2. Read `GetEventKind(eventRef)` as well as `EventHotKeyID` and dispatch to `onPressed` or a new `onReleased` closure on the main actor.
3. Add a per-hotkey edge latch. Deliver only the first pressed event while down and only the matching release; ignore unmatched releases and repeated pressed events. Reset the latch on release and `unregister()`.
4. Do not add a time debounce. Edge latching prevents key-repeat toggles without suppressing legitimate fast press/release cycles.

This remains the single Carbon handler/target registry used by F13, Option-Command-D, and Esc. Option-Command-D and Esc need no release action, but benefit from repeat suppression.

### Deferred and active intent

Replace the ambiguous `wantsListening` Boolean with explicit intent tracking, using proposed internal symbols `DictationStartIntent` (`.manualToggle`, `.micHold`) and `DictationIntentTracker` (`pending`, `active`):

- A hold down may queue `.micHold` while the app is `.starting` or `.downloading`; this is the behavior needed when F13 is pressed during bootstrap/warm-up.
- On readiness, `beginListening()` runs only if a pending intent still exists, #4's supervisor is `.running` as established solely by HTTP `/health` 200, and the persistent WebSocket is connected. Move pending -> active only after permission checks and `AudioCapture.start` succeed.
- Hold up:
  - Pending `.micHold`: clear it and do not commit or enter `.flushing`; startup may continue normally to `.ready`.
  - Active `.micHold` in `.listening`: call the existing `stopDictation()` commit/flush path.
  - Active hold interrupted by transport or speech-runtime loss: clear its ownership, so reconnecting cannot restart capture and the later physical release is a no-op.
  - No matching hold intent, or `.flushing`: no-op; never stop a session that the hold press did not own and never send a duplicate commit.
- Toggle/manual starts retain today's normal state rules. They are not converted into hold semantics.
- On WebSocket or speech-runtime loss while actively listening, classify the session as interrupted: stop capture, preserve text already inserted live, discard any terminal-target buffer, and clear intent. Reconnection may restore Ready but must never reopen the microphone without a new user request. Audio-start failure, Esc, and completed finalization also clear intent deterministically through their respective failure, cancellation, and completion paths.

Keep `DictationState` unchanged. Physical-key state and pending intent are orthogonal to the existing server/session UI states and do not warrant new status colors or menu states.

### Esc and stale realtime output

Use the server's clear acknowledgement as a cancellation barrier:

- Add `Callbacks.onBufferCleared` in `RealtimeClient` and recognize `input_audio_buffer.cleared`.
- Remove the unconditional `clearBuffer()` from `beginListening()`. The server is already reset by normal final completion, acknowledged cancellation, or a new WebSocket. This ensures every clear acknowledgement belongs to an actual cancellation; an older start-time acknowledgement cannot prematurely open the barrier.
- On Esc, perform all local cancellation immediately as today, mark `awaitingBufferClear`, then send clear. Hide the indicator and return to `.ready`/`.starting` without waiting.
- While awaiting the acknowledgement, drop all delta/done events. More generally, accept transcript events only in `.listening` or `.flushing`.
- If a new start is requested before acknowledgement, keep it pending. Begin only after `onBufferCleared`; a hold release before that clears the pending hold.
- A disconnect clears the barrier because a new WebSocket owns a fresh server `StreamingSession`.
- Make `commitFinal()`/`clearBuffer()` report whether a frame was enqueued. If commit cannot be enqueued, do immediate active-session teardown and move to reconnecting rather than remaining `.flushing`; if clear cannot be enqueued, rely on/newly initiate reconnect rather than waiting for an acknowledgement that cannot arrive.

This preserves “Esc is immediate” locally while preventing trailing finalization output from leaking into the canceled or next session. It uses the protocol already implemented by the repository and avoids adding request IDs or Python changes.

### Lifecycle table

| Input/event | Existing state | Result |
|---|---|---|
| Hold F13 down | `.ready` | Validate, begin capture, `.listening` |
| Hold F13 down | `.idle`/`.starting`/`.downloading` | Queue `.micHold`; start/continue readiness work |
| Hold F13 up | pending before ready | Clear pending; never enter `.listening`/`.flushing` |
| Hold F13 up | active `.listening` | Existing final commit path -> `.flushing` -> `.ready` |
| Hold F13 up | no owned hold or already `.flushing` | No-op |
| Toggle F13 down | `.ready`/`.listening` | Existing start/stop toggle behavior |
| Toggle F13 up | any | No-op |
| Option-Command-D/menu | any | Existing manual toggle behavior, independent of mic mode |
| Esc | `.listening`/`.flushing` | Immediate local teardown; clear barrier; stale output ignored |
| Ready/connected callback | pending intent exists | Begin only if still pending and reset barrier is open |

Secure Input and Accessibility are checked on the initiating down/start request and again immediately before delayed capture begins. Refusal clears pending intent; the corresponding key up cannot commit.

## 3. Ordered file-by-file changes and ownership

Implement against the post-#5 tree. In particular, **do not create or reconfigure a test target, resolver, launch command, supervisor seam, package layout, or defaults domain in #2**.

1. **Tests under the shared `app/Tests/LocalDictationTests/` target created by #4**
   - Reuse #4's target, support fixtures, and naming conventions; do not edit `app/Package.swift` merely to create another target.
   - Add `MicKeyGestureInterpreterTests.swift`: hold down/up actions, toggle down/up actions, mode latched across a mid-press preference change, unmatched release ignored, repeated down ignored, and a fresh cycle accepted after release/reset.
   - Add `DictationIntentTrackerTests.swift`: pending hold canceled by release before readiness; readiness does nothing after cancellation; pending hold activates when still held; active hold release requests one stop; release during reconnect removes requeued hold intent; manual/toggle intent is not ended by an unrelated hold release; Esc/failure reset clears all intent.
   - Add `MicKeyModePreferenceTests.swift`: missing/invalid values fall back to toggle, and both raw values round-trip through an isolated suite without polluting `com.omcdowell.LocalDictation`.
   - Add reset/transcript-gate coverage if that logic is extracted: deltas/done are rejected after cancellation until clear acknowledgement, and a pending hold released during the barrier does not start when acknowledgement arrives.

2. **New: `app/Sources/LocalDictation/DictationInput.swift`**
   - Define `MicKeyMode`, display titles/raw persisted values, and missing/invalid-value fallback to `.toggle`.
   - Define a small `MicKeyGestureInterpreter` that latches the mode on down and emits `.beginHold`, `.endHold`, or `.toggle`; expose `reset()` for shutdown/registration reset.
   - Define the small, pure `DictationStartIntent`/`DictationIntentTracker` used by `DictationController` to distinguish pending and active manual/hold requests. Keep it free of AppKit/Carbon so release-before-ready and interruption behavior can be unit-tested in #4's shared target.
   - If the Carbon edge latch is made a pure helper (`HotKeyEdgeLatch`), place it here and use it from `CarbonHotKey`.

3. **`app/Sources/LocalDictation/App.swift` — controller/input lifecycle**
   - Replace `wantsListening` with `DictationIntentTracker` plus an `awaitingBufferClear` reset barrier. This is #2's explicit pending/active input model that #1 will later consume.
   - Add explicit `beginHoldDictation()` and `endHoldDictation()` entry points; retain `toggleDictation()` for F13 toggle mode, the dev hotkey, and the menu.
   - Refactor common start checks into one request path. Queue hold intent during `.starting`/`.downloading`; do not start unless the intent is still pending, #4's supervisor reports `.running` after `/health` 200, and the WebSocket is connected.
   - Treat the supervisor as a dependency with the generation-safe behavior and structured states established by #4. Do not inspect output markers, add a second readiness timer, alter desired-running state, or duplicate launch/restart diagnostics.
   - In `beginListening()`, revalidate Secure Input/Accessibility, start audio, then activate the pending intent. Remove the start-time `realtime.clearBuffer()`.
   - Keep `stopDictation()` as the sole final commit path. Handle an immediate `commitFinal()` enqueue failure by stopping/discarding/hiding and following #4's existing reconnect/failure state rather than waiting in `.flushing`.
   - Clear or requeue intent consistently in `handleServerState(_:)`, `handleConnectionState(_:)`, realtime error handling, audio-start failure, `handleDone(_:)`, and `cancelDictation()`. Preserve #4's structured diagnostics rather than replacing them with input-specific server errors.
   - Gate `handleDelta(_:)`/`handleDone(_:)` to an active state and the open reset barrier. Add `handleBufferCleared()` to open the barrier and service any still-pending start.
   - Ensure Esc clears pending/active hold ownership before returning state, so a later F13 up is harmless.

4. **`app/Sources/LocalDictation/App.swift` — preferences/menu/hotkeys**
   - Add the mic-mode preference key to `AppPrefs` and read/write it through the shared defaults object/suite `com.omcdowell.LocalDictation` established by #5. Do not add another suite or derive identity from the development executable.
   - Add the **Mic Key Mode** submenu and two checked/radio-style items. Selector actions persist the raw mode and refresh checkmarks. Do not restart or stop the current session when the preference changes.
   - Give F13 separate pressed/released callbacks routed through `MicKeyGestureInterpreter`. Keep `toggleHotKey.onPressed` and `#selector(toggleDictation)` directly wired to the always-toggle path.
   - Update remap-success copy so it describes the selected mic mode and explicitly says Option-Command-D remains toggle.
   - Reset the F13 interpreter during quit after unregistering hotkeys.
   - Extend `CarbonHotKey` with `onReleased`, both Carbon event kinds, event-kind dispatch, and per-key edge/repeat suppression. Preserve the shared handler/`targets[(signature,id)]` architecture.
   - Preserve #5's packaged-app menu and Launch at Login integration; insert the mode submenu into that landed menu without recreating either.

5. **`app/Sources/LocalDictation/RealtimeClient.swift`**
   - Make only the narrow session-cancellation changes required by #2: add `Callbacks.onBufferCleared`, dispatch `input_audio_buffer.cleared`, and let `commitFinal()`/`clearBuffer()` report immediate enqueue success via `sendJSON(_:)`.
   - Preserve existing asynchronous send-failure behavior and #4's supervisor/client integration. Do not turn this into a second transport or process-supervision rewrite.

6. **`app/Sources/LocalDictation/MicKeyManager.swift`**
   - Update comments that call F13 “toggle” to describe selectable hold/toggle behavior.
   - Keep HID constants/remap JSON/permission guidance unchanged. In particular, retain the compatibility LaunchAgent label **`com.local-dictation.keyremap`** even though the app identity/defaults suite is `com.omcdowell.LocalDictation`.

7. **`README.md`**
   - Update the opening and Usage sections for the selectable hold-to-talk mode, press-to-toggle default, persisted selection, and Option-Command-D remaining toggle.
   - Merge into #4/#5's landed portable-path, packaged-helper, diagnostics, install, and Launch at Login documentation; do not replace or restate those contracts. Keep `/health` as the only documented readiness signal.

8. **`PLAN.md`**
   - Change only stale trigger/flow/verification statements: describe selectable hold/toggle, release-to-finalize in hold mode, and remove hold-to-talk from “out of scope.” Do not rewrite the historical architecture or #4/#5 packaging/resolution decisions.

**Files owned elsewhere and not functionally changed by #2:**

- `app/Package.swift` and shared test infrastructure: #4 first, then #5 only as packaging requires.
- `AppConfig.swift`, `ServerSupervisor.swift`, server launch resolver/diagnostic types: #4; #5 only extends packaged resolution; #1 later adds narrowly scoped idle desired-running/stop-reason behavior.
- `.app` assembly, helper runtime, signing, `Info.plist`, package verification, `SMAppService`: #5.
- Python sources, `server/pyproject.toml`, and `Makefile`: no #2 changes.
- `AudioCapture.swift`, `TextInserter.swift`, `IndicatorPanel.swift`, and `IndicatorSounds.swift`: no functional #2 changes.

## 4. Tests and acceptance verification

Run automated checks after each green slice:

```bash
cd app
swift test
swift build
```

Then perform on-target checks with the remap active, Accessibility/Microphone/Input Monitoring granted, and system Dictation/Siri mic shortcuts disabled.

| Acceptance criterion | Automated coverage | Manual verification |
|---|---|---|
| **AC1: Hold down starts; up commit+flushes to ready** | Gesture hold edges and one-stop intent tests; build verifies Carbon symbols | Select Hold to Talk. In TextEdit, press and keep holding F13/🎤: verify one start sound, indicator, `.listening`, and live text. Release: verify immediate audio stop, `.flushing`, trailing text, one stop sound, then `.ready`. Hold beyond macOS repeat delay and confirm no extra action. Repeat in a terminal to confirm one sanitized buffer insertion on release. |
| **AC2: Toggle mode remains** | Toggle press emits one toggle and release emits none; repeat-down test | Select Press to Toggle. First F13 press/release starts and remains listening; second press stops/flushing. Hold each press beyond repeat delay. In both preference modes, verify Option-Command-D and menu Start/Stop still toggle. |
| **AC3: Menu selection persists** | Mode raw-value/default/round-trip tests | Verify submenu checkmarks are mutually exclusive. Select Toggle, quit/relaunch, confirm Toggle and behavior; repeat for Hold. Confirm changing the menu while a physical press is in flight affects only the next F13 gesture. |
| **AC4: Esc during listening and flushing in both modes** | Intent reset and transcript reset-barrier tests | For each mode, press Esc while listening: indicator/audio stop immediately; stream text already inserted stays; terminal buffer inserts nothing. For each mode, initiate stop/release then immediately press Esc during `.flushing`: no late terminal insertion or stale stream delta, app returns ready/starting, and the next session starts with a clean transcript. |
| **AC5: Brief hold before ready cannot stick** | Pending-hold-release-before-ready test and reset-barrier pending-release test in #4's shared target | Launch during first-model download/server warm-up (using #4/#5's output/activity-aware timeout path) or a supervised reconnect, press and release F13 before Ready, then wait for `/health` 200 and WebSocket connection. Verify no indicator/audio start, no `.listening`/`.flushing`, and final state `.ready`. Also rapidly tap while Ready and verify an empty/short final reaches `.ready`; no stdout ready marker may be involved. |

Additional regression checks:

- With Secure Input active, both hold and toggle starts are refused on down; release sends no commit. Repeat with Accessibility revoked. Restore grants and verify a later gesture can start.
- Start via Option-Command-D, then press/release F13 in hold mode; the unrelated hold must not claim/stop the manual session. Stop via Option-Command-D or menu.
- While listening, force a WebSocket disconnect in both hold and toggle modes. Verify the session is interrupted, terminal-target text is discarded, inserted live text remains, reconnection returns to Ready without reopening the microphone, and a fresh user gesture is required.
- Verify remap install/remove and LaunchAgent persistence are unchanged.
- Check Console logs for exactly one F13 down and up per physical cycle and no duplicate commit under key repeat.

## 5. Races, edge cases, failure behavior, and observability

- **Release before readiness:** pending intent, not `DictationState`, is authoritative. Up removes `.micHold`; later ready callbacks must re-check pending intent before capture.
- **Main-queue ordering:** Carbon edges and supervisor/realtime callbacks converge on `@MainActor`. A ready callback processed before up may start a very short real session, after which up legitimately commits; if up is processed first, readiness must not start. Neither ordering can strand the app.
- **Key repeat:** use a down/up edge latch, not elapsed-time debounce. Repeated `kEventHotKeyPressed` events cannot toggle/commit repeatedly.
- **Mode changed while down:** the gesture interpreter uses the down-latched mode. Menu state changes immediately for the next cycle only.
- **Unmatched release/app launched while key held:** ignore release without a delivered down. `unregister()` resets latches so stale physical state does not survive teardown.
- **Hold pressed over an existing manual session:** reject ownership; its release is a no-op. This prevents F13 from unexpectedly stopping a dev/menu-started session.
- **Permission/audio-start refusal:** clear pending intent before entering `.error`; release is harmless. Recheck permissions after a delayed warm-up because the focused/secure-input context may have changed.
- **Commit enqueue failure:** never remain `.flushing` if no commit frame was queued. Tear down locally and enter the existing reconnect/start path. Asynchronous send failure continues through existing error/disconnect callbacks.
- **Esc during finalization:** server finalization is synchronous and may send trailing output before processing clear. Local cancellation remains immediate; the clear-ack barrier drops those events and delays a new start until server ordering proves reset complete.
- **Clear acknowledgement correctness:** remove start-time clears so there is no older acknowledgement that can satisfy a later cancellation barrier. Normal `.done`, acknowledged Esc clear, and reconnect are the only reset paths.
- **Barrier connection loss:** disconnect opens the barrier because the old server session is unreachable and the replacement WebSocket creates a new `StreamingSession`. Clear active intent and treat the session as interrupted; neither a held key nor toggle ownership may requeue it automatically.
- **Esc after hold release:** release has already entered `.flushing`; Esc clears intent and cancels. A subsequent duplicate release/commit is suppressed.
- **Very short active hold:** it may contain no full audio chunk because `AudioCapture.stop()` discards pending bytes. Still send one final commit and wait for the server's empty `.done`; do not invent a minimum hold duration.
- **Lost Carbon release:** Carbon's registered-hotkey API supplies `kEventHotKeyReleased` on supported macOS and is the chosen native mechanism. Esc/menu remain recovery controls. Do not add an event tap or timer that would require permissions or prematurely stop a genuinely held key; validate the remapped F13 release empirically on macOS 15/26.
- **Observability:** add input/session events to #4's landed structured diagnostic/logging path for F13 down/up with latched mode, repeat/unmatched-edge suppression, queued/activated/canceled intent, release-before-ready, commit enqueue failure, Esc reset begin/ack, and stale transcript drops. Do not create a second server diagnostic model or new visible server state; #4's status/menu diagnostics and the existing dictation state/menu/indicator transitions remain authoritative.

## 6. Dependencies/conflicts with issues #1–#5 and landing order

The issue branches began at the same initial commit, but implementation must be serialized under the following ownership contract.

- **#4 — Ops: portable server path and in-app errors (lands first)**
  - Owns the first shared Swift test target and reusable fixtures/test seams.
  - Owns portable resolution, structured diagnostics, `/health`-only readiness, output/activity-aware startup/download timeout behavior, and generation-safe process supervision.
  - Owns the general `ServerLaunchCommand` abstraction with `executableURL`, `argumentPrefix`, and `source`.
  - Defines the future packaged candidate as `Contents/Helpers/LocalDictationServer/bin/python3` plus argument prefix `["-I", "-B", "-u", "-m", "local_dictation_server.server"]`. It must not define a `Resources/server` console-script contract.
  - #2 consumes its supervisor states/test target and must not recreate any of these pieces.

- **#5 — Package as a distributable macOS app (lands second)**
  - Consumes and extends #4's resolver/supervisor instead of creating a duplicate resolver or process path.
  - Owns actual `.app` assembly, the self-contained Python runtime at the helper path above, signing, `Info.plist`, package verification, and installed-app `SMAppService` behavior.
  - Establishes stable bundle ID/defaults suite `com.omcdowell.LocalDictation`. #2 stores its mode in that suite.

- **#2 — Hold-to-talk mic key (this plan; lands third)**
  - Owns Carbon pressed/released delivery, key-repeat edge latching, the hold/toggle mic preference, F13 gesture routing, explicit pending/active input intent, release-before-ready, and the narrow Esc/session-clear barrier.
  - Reuses #4's shared test target/fixtures and #4/#5 startup, diagnostics, resolver, packaged identity, and packaged-app menu structure.
  - Does not change `ServerLaunchCommand`, supervisor generations/readiness, package assembly, signing, `SMAppService`, or the helper runtime.

- **#1 — Unload ASR server after idle (lands fourth)**
  - Layers idle scheduling and desired-running intentional stop/relaunch onto #4's generation-safe supervisor and #2's pending/active input model.
  - Adds only missing stop-reason/generation behavior needed to distinguish idle unload from crashes. It must not introduce a second broad supervisor/client rewrite or regress `/health`-only readiness.
  - A hold released during cold wake-up clears #2's pending capture intent; #1 decides desired server-running/idle scheduling without treating that canceled hold as a completed dictation session.

- **#3 — Guided first-run onboarding (lands fifth)**
  - Lands against the packaged identity `com.omcdowell.LocalDictation` and the final menu after #1/#2/#5.
  - Reuses #2's preference/mode wording and #4's diagnostics; it must not duplicate preference storage, server-error UI, resolver status, or test infrastructure.
  - Retains the existing compatibility LaunchAgent label `com.local-dictation.keyremap`.

**Recommended serial landing order: `#4 -> #5 -> #2 -> #1 -> #3`.**

Rebase #2 onto #5 before implementation. During conflict resolution, preserve #4's supervisor/resolver/diagnostic/test ownership and #5's package identity/menu/SMAppService ownership, then layer only #2's input intent and mode behavior. Later issues add cases and fixtures to the one shared test target rather than adding targets of their own.

## 7. Incremental commit / tracer-bullet sequence

Start only after #4 and #5 are landed/rebased. Keep every #2 commit buildable and green using the shared test target that #4 already created.

1. **`test: add mic-key input state coverage`**
   - Add #2 test files/fixtures to the existing shared target alongside pure `MicKeyMode`, gesture interpreter/edge latch, and intent-tracker seams. Do not edit `Package.swift` to create another target.
2. **`feat: add selectable hold and toggle F13 gestures`**
   - Subscribe to Carbon pressed/released events, suppress repeats, route F13 through the latched mode, persist via `com.omcdowell.LocalDictation`, merge the mode submenu into #5's packaged-app menu, and retain Option-Command-D/menu toggle. Demonstrate the end-to-end hold path when `/health` has made #4's supervisor `.running` and the WebSocket is connected.
3. **`fix: cancel hold requests released before readiness`**
   - Replace `wantsListening`, wire pending/active intents through #4's landed supervisor states and existing reconnect/failure seams, and add release-before-ready coverage. Do not alter `ServerLaunchCommand`, readiness, generations, diagnostics, or startup timeout policy.
4. **`fix: quarantine realtime output after Esc cancel`**
   - Add only clear-acknowledgement handling, enqueue results, start-time-clear removal, transcript gating, and Esc/reset race tests to the existing client/controller.
5. **`docs: document hold-to-talk mic mode`**
   - Update `README.md`, focused `PLAN.md` statements, and stale `MicKeyManager` comments while preserving #4/#5's portable packaged-helper, health-only readiness, diagnostics, packaging, and `SMAppService` documentation; complete the manual matrix before landing.

## 8. Explicit assumptions and decisions

- #2 is rebased onto completed #4 and #5. Their resolver, `ServerLaunchCommand`, supervisor generations/test seams, diagnostics, `/health`-only readiness, activity-aware model-download timeout, package layout, and installed-app behavior are prerequisites—not work owned by #2.
- Default for a missing/invalid preference is **Press to Toggle**, preserving existing behavior; selecting either menu item persists it in the stable `com.omcdowell.LocalDictation` defaults suite.
- The application bundle ID is `com.omcdowell.LocalDictation`. The pre-existing remap LaunchAgent label remains `com.local-dictation.keyremap` for compatibility and is not renamed or migrated by #2.
- The preference governs only F13/the remapped mic key. Option-Command-D and menu Start/Stop remain toggle controls for development and recovery.
- Any accepted hold that actually reaches `.listening` uses the existing final commit path on release, even if extremely short. A hold released before capture starts is canceled without commit.
- The server may continue booting after a pending hold is released; only listening intent is canceled. #1 later layers idle desired-running/intentional-stop behavior onto #4's supervisor and this intent model.
- Esc does not retract stream text already posted before cancellation. It discards terminal-buffer text and all transcript output observed after the cancellation barrier begins.
- No event tap, third-party hotkey package, timing threshold, settings window, protocol request ID, Python/server change, AppConfig schema change, test target, resolver, supervisor rewrite, or packaging change is needed for #2.
- Existing `DictationState` cases remain the public/UI state machine; input ownership and reset-barrier state stay internal. Server readiness remains exclusively HTTP `/health` 200; WebSocket connection is a separate prerequisite to capture.

**Genuinely unresolved questions:** none. Carbon F13 release delivery after the `hidutil` remap is an on-target verification item, not an open design decision; the local macOS SDK explicitly provides registered-hotkey pressed and released events.
