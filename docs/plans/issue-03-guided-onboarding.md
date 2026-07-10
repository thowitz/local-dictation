# Issue #3 implementation plan — Guided first-run onboarding

Planning baseline: `main` at `17e3091` on 2026-07-10. This is an AppKit menu-bar executable with a small existing SwiftUI surface; no repository changes are part of this planning pass.

## 1. Current state and code paths

### Launch, menu, and one-shot first-run behavior

- `app/Sources/LocalDictation/App.swift`
  - `AppDelegate.applicationDidFinishLaunching(_:)` registers the dev and F13 `CarbonHotKey`s, builds the status-item menu, immediately requests microphone access through `AudioCapture.requestMicrophoneAccess()`, starts `DictationController.bootstrap()`, then calls `runFirstRunChecksIfNeeded()`.
  - `AppPrefs.firstRunChecksCompleted` is a single `UserDefaults.standard` Boolean. `runFirstRunChecksIfNeeded()` writes it **before** evaluating the checks or receiving any user confirmation. Closing the alert, opening one pane, or failing to change a setting all permanently suppress the prompt.
  - `runFirstRunChecksIfNeeded()` is one modal `NSAlert` concerned only with Dictation and Siri. It has no ordered Mic/Accessibility/Input Monitoring/remap flow, no live refresh, and no menu re-entry.
  - The direct `installMicKeyRemap()` menu action always installs both the active mapping and the LaunchAgent. Persistence is not optional. It uses separate alerts for success, Input Monitoring guidance, and failures.
  - `refreshPermissionRows()` displays microphone and Accessibility state. Microphone is not actionable; Accessibility uses another ad-hoc alert in `promptAccessibilityPermission()`.
  - `refreshRemapItems()` calls `MicKeyManager.verifyRemap()` and `isLaunchAgentInstalled()`, but only after launch/menu setup and explicit install/remove actions. There is no wake/login health check.
  - F13 is registered unconditionally. A missing HID mapping therefore causes the hardware mic key to keep its system behavior; the app receives no signal that the mapping disappeared.
- The current raw SwiftPM executable stores standard defaults under the `LocalDictation` domain on this machine. It already has `firstRunChecksCompleted = true`, illustrating why the new flow needs a versioned completion marker rather than reusing that Boolean.

### Existing permission and conflict probes

- `app/Sources/LocalDictation/AudioCapture.swift`
  - `AudioCapture.microphoneAuthorizationStatus()` is an authoritative public status query.
  - `AudioCapture.requestMicrophoneAccess()` is the public asynchronous request path. Once denied, the app must deep-link to System Settings; requesting again does not provide a useful in-app recovery flow.
- `app/Sources/LocalDictation/App.swift`
  - Accessibility is queried authoritatively for the current process with `AXIsProcessTrusted()`.
  - `promptAccessibilityPermission()` invokes `AXIsProcessTrustedWithOptions` with `AXTrustedCheckOptionPrompt`; that prompt is asynchronous, so its immediate return value cannot be treated as the post-prompt state. The current code already has the Accessibility deep link.
  - `DictationController.startDictation()` and `beginListening()` refuse to start without Accessibility, so onboarding must reflect the same check rather than invent a second definition.
- `app/Sources/LocalDictation/FirstRunChecks.swift`
  - `FirstRunChecks.evaluate()` first reads `AppleSymbolicHotKeys[164].enabled`, then falls back to `com.apple.HIToolbox/AppleDictationAutoEnable`; it returns `.unknown` if neither is readable.
  - `siriHoldF5` is intentionally always `.unknown`: no stable public preference exists across the supported macOS versions.
  - `openDictationSettings()` and `openSiriSettings()` already use the native `x-apple.systempreferences:` links for Keyboard and Apple Intelligence & Siri.
  - On the current target machine, hotkey 164 is explicitly disabled while `AppleDictationAutoEnable` is 1. The explicit hotkey value correctly takes precedence. The UI must expose “appears off/on/unknown,” not claim that either fallback is a guaranteed representation of the current System Settings UI.
- Input Monitoring limitation:
  - CoreGraphics exposes `CGPreflightListenEventAccess()` and `CGRequestListenEventAccess()`, but those answer whether the **current process** may listen to events. LocalDictation uses Carbon hotkey registration, not a listening event tap, and delegates remap mutation to `/usr/bin/hidutil`.
  - Therefore those APIs are not an authoritative test of whether the child `hidutil` operation will work. Do not label Input Monitoring “Granted” from `CGPreflightListenEventAccess()`.
  - The repository’s existing functional probe is the correct source of truth for this feature: run `hidutil --set`, then read `UserKeyMapping` and verify that the exact mic→F13 entry exists. A set that exits but does not produce the mapping becomes `.needsInputMonitoring`; the UI should still describe this as the likely cause, not a proven TCC diagnosis.

### Existing remap and persistence probes

- `app/Sources/LocalDictation/MicKeyManager.swift`
  - `installRemap()` runs `/usr/bin/hidutil property --set …`, then calls `verifyRemap()`. It already distinguishes process failure from an ineffective set and provides the Input Monitoring URL/copy through `MicKeyInputMonitoringGuidance`.
  - `verifyRemap()` collapses “mapping absent” and “probe failed” to `false`. A health monitor must not alert “mapping lost” when `hidutil --get` itself failed.
  - `userKeyMappingContainsOurRemap(_:)` first accepts any output containing the source and destination values anywhere. With multiple entries, unrelated source/destination entries can produce a false positive. It should instead parse entries and require the values to occur in the same dictionary. Current `hidutil` output is an OpenStep property-list array with decimal string values; JSON is also supported and must remain supported.
  - `installLaunchAgent()` writes a `RunAtLoad` one-shot job at `~/Library/LaunchAgents/com.local-dictation.keyremap.plist`, then bootouts/bootstrap it in `gui/<uid>`.
  - `isLaunchAgentInstalled()` checks only file existence. It does not validate label, arguments, mapping, or whether launchd has loaded the job.
  - A healthy one-shot job is normally “not running.” On the current machine `launchctl print gui/501/com.local-dictation.keyremap` succeeds, reports `state = not running`, `runs = 1`, and `last exit code = 0`; “not running” must not be treated as unhealthy.
  - `RunAtLoad` re-applies at login, not on every wake/device reconnection. Wake handling must verify the active mapping and restore it if needed.
- `README.md`, `PLAN.md`, and `Makefile` document the same remap, Input Monitoring guidance, and LaunchAgent strategy. `make remap` is deliberately session-only; the app currently has no equivalent option.

### Package/test surface at the planning baseline

- `app/Package.swift` currently has one executable target and no test target or third-party dependency.
- `server/pyproject.toml` and all Python server paths are unrelated to onboarding; issue #3 must not change them.
- There are currently no Swift tests on `main`, but #3 lands last in the agreed sequence. By then #4 owns and has already added the **single shared Swift test target**, its common fixtures, and process/supervision test seams. #3 adds test files and issue-specific fixtures to that target; it does not add another target or independently recreate the harness.

### Required integration baseline before #3

Issue #3 must be planned against the serially landed #4, #5, #2, and #1 code, not directly against the initial commit’s server/hotkey behavior:

- **#4 baseline:** portable server resolution; structured launch diagnostics; generation-safe process supervision and test seams; `/health` returning 200 as the **only** readiness condition; and a general `ServerLaunchCommand` containing `executableURL`, `argumentPrefix`, and `source`.
- **#5 baseline:** a signed, installed `.app` with stable bundle ID `com.omcdowell.LocalDictation`, self-contained Python runtime, Info.plist/privacy declarations, packaging verification, and installed-app `SMAppService` behavior. It consumes/extends #4’s resolver and supervisor rather than adding parallel launch logic.
- The packaged `ServerLaunchCommand` contract is exactly:
  - executable: `Contents/Helpers/LocalDictationServer/bin/python3` relative to the app bundle;
  - argument prefix: `["-I", "-B", "-u", "-m", "local_dictation_server.server"]`;
  - source: the packaged-helper source case defined by #4/#5.
  It is **not** a `Resources/server` console-script contract.
- **#2 baseline:** Carbon press and release delivery, persisted mic-key mode, and explicit pending/active input intent. Default hardware mic-key behavior remains press-to-toggle for compatibility; hold-to-talk is opt-in, and the dev hotkey and menu command remain toggle actions.
- **#1 baseline:** idle scheduling and desired-running intentional stop/relaunch layered on #4’s supervisor and #2’s intent model, with only the missing stop-reason/generation behavior added—not a second supervisor/client rewrite.
- First model download uses the output/activity-aware timeout behavior established by #4/#5. #3 must not restore `VOXMLX_READY` as readiness, add another timeout policy, or couple setup completion to server readiness.

## 2. Chosen design and state/lifecycle changes

### UX: one retained native checklist window

Add a retained AppKit `NSWindowController` whose content is an `NSHostingController`/SwiftUI checklist. This matches the repository’s existing AppKit lifecycle and SwiftUI hosting pattern without adopting a new app lifecycle or dependency.

The window is titled **Local Dictation Setup**, is closable and resizable only if needed for accessibility, and contains one vertically scrollable ordered checklist:

1. **Microphone**
   - Show Authorized / Not requested / Denied / Restricted / Unknown.
   - If not determined, primary action is **Request Microphone Access**.
   - If denied/restricted, primary action is **Open Microphone Settings** and the row explains that a relaunch may be needed.
2. **Accessibility**
   - Show `AXIsProcessTrusted()`.
   - Primary action invokes the native AX prompt and opens Privacy & Security → Accessibility.
3. **Input Monitoring**
   - Explain that macOS does not expose a reliable status for this `hidutil` child-process use.
   - Primary action opens Privacy & Security → Input Monitoring.
   - Persist a user confirmation (“I enabled/reviewed Input Monitoring”). If remap installation returns `.needsInputMonitoring`, show that functional failure on this row and keep the remap row incomplete.
4. **Mic-key remap**
   - Show active mapping state separately from persistence state.
   - Primary action is **Install/Test Remap** and uses `MicKeyManager.installAndVerifyRemap()`.
   - Include **Reapply at login (recommended)**, default on. If selected, install and validate the LaunchAgent. If unselected, remove an existing app-owned LaunchAgent and retain a session-only active mapping.
5. **System Dictation shortcut**
   - Render `FirstRunChecks.evaluate().dictationShortcut` as Detected on / Appears off / Could not verify, including best-effort wording.
   - Primary action opens Keyboard settings. Permit a persisted manual “I confirmed Shortcut is Off” because preference data can be absent or stale.
6. **Siri press-and-hold F5**
   - Usually render Not automatically detectable.
   - Primary action opens Apple Intelligence & Siri. Require a persisted manual confirmation unless a future probe can return `.disabled`.

Use standard SwiftUI controls (`ScrollView`, numbered row labels, status icon/text, `Button`, `Toggle`) and system colors. Do not add a custom design system or multi-page wizard. A **Refresh** button re-reads all probes. **Finish Setup** is enabled only when all required conditions below are met. Closing the window is “finish later” and does not mark completion.

### New state model

Add internal feature state with these responsibilities:

- `SetupStepID`: the fixed order above.
- `SetupSnapshot`: one immutable render snapshot containing app-specific microphone state, AX trust, Input Monitoring confirmation/latest functional error, `MicKeyRemapStatus`, `LaunchAgentStatus`, `FirstRunCheckReport`, persisted confirmations, and derived per-step/overall completion.
- `SetupPreferences` (`@MainActor`): the only reader/writer for feature defaults.
- `OnboardingCoordinator` (`@MainActor`, `ObservableObject`): publishes the snapshot, performs row actions, refreshes after actions/activation, and writes completion only from `finishSetup()`.
- `OnboardingWindowController`: owns/reuses one window, calls `refresh()` before every show, and activates the accessory app/window without creating a Dock app.

Derived “currently complete” conditions:

- microphone is authorized;
- Accessibility is trusted;
- Input Monitoring has been manually confirmed;
- the exact mic→F13 mapping is active;
- if reapply-at-login is selected, the LaunchAgent plist is valid and the job is loaded (a loaded one-shot job need not be running);
- Dictation is reported disabled **or** manually confirmed off;
- Siri is reported disabled **or** manually confirmed off.

If an automatic Dictation probe still says enabled while the user has confirmed it off, show a warning that the probe disagrees but allow the explicit confirmation to win; the API is best-effort and the acceptance criterion is conditional on the user following the checklist. Refresh remains available.

### Persisted state and migration

Use the packaged app’s stable bundle/defaults identity, `com.omcdowell.LocalDictation`. `SetupPreferences` should read/write that suite explicitly so tests can inject an isolated suite while production matches #5’s bundle identity. Keep all keys centralized:

- `setup.completedVersion` (current version `1`);
- `setup.inputMonitoringConfirmed`;
- `setup.dictationShortcutConfirmedOff`;
- `setup.siriHoldF5ConfirmedOff`;
- `micKey.expectedActive`;
- `micKey.persistenceDesired`.

Rules:

- Do **not** migrate `AppPrefs.firstRunChecksCompleted` to `setup.completedVersion`; the old Boolean did not represent completion.
- On first migration only, if a valid app-owned LaunchAgent already exists, seed `micKey.expectedActive = true` and `micKey.persistenceDesired = true`. Do not infer an expectation merely from a session-only active mapping, which may have come from `make remap`.
- Default `micKey.persistenceDesired` to true for a new install.
- Set `micKey.expectedActive = true` only after the remap has been functionally verified. This remains true for session-only installs, so after reboot the app can ask to restore it for the new login.
- Explicit **Remove mic-key remap** clears `micKey.expectedActive` and `micKey.persistenceDesired` so the health monitor respects user intent. It does not erase the setup confirmations.
- Set `setup.completedVersion = 1` only from enabled **Finish Setup**. Closing the window leaves it unset, so the checklist auto-opens on the next launch.
- A later permission regression does not erase historical completion or force the whole wizard open. Reopening the checklist always reflects live state; missing expected remap has its own proactive recovery behavior.

### App lifecycle

Replace the current launch sequence with:

1. Preserve the final status item and #2 input wiring: the hardware mic key defaults to press-to-toggle, with opt-in hold-to-talk implemented through Carbon press/release and pending/active intent; the dev hotkey and menu action remain toggle. Onboarding does not register another hotkey or add a mic-mode preference.
2. Construct `SetupPreferences`, `OnboardingCoordinator`, `OnboardingWindowController`, and `RemapHealthMonitor`; retain them from `AppDelegate`.
3. Remove the unconditional startup microphone request. Permission prompts happen only from their ordered row.
4. Leave #1’s desired-running/idle lifecycle and #4’s health-only supervisor running independently. Onboarding must not wait for server/model readiness, mutate pending/active input intent, or interpret server state as setup state.
5. On the next main-run-loop turn, auto-show the checklist if `setup.completedVersion < 1`.
6. Schedule a launch remap-health check only when `micKey.expectedActive` is true. Suppress a separate missing-remap alert while the incomplete/visible setup window already shows the problem.
7. Refresh the snapshot whenever the setup window is shown, when the app/window becomes active again after System Settings, and when the status menu opens.
8. Observe `NSWorkspace.didWakeNotification` and `NSWorkspace.sessionDidBecomeActiveNotification` and schedule remap-health checks. Remove observers/cancel tasks on termination.

### Remap health and recovery

Add `RemapHealthMonitor` with a small pure assessment policy plus lifecycle scheduling:

- Inputs: `expectedActive`, `persistenceDesired`, `MicKeyRemapStatus`, and `LaunchAgentStatus`.
- Outcomes: healthy, active-but-persistence-needs-repair, expected-mapping-missing, or probe-failed.
- Launch check: wait about 2 seconds for the login LaunchAgent, then retry a missing mapping twice at short intervals before alerting.
- Wake/session-active check: wait about 1 second for HID services to settle, then retry once.
- Never turn a probe error into a “mapping is missing” alert. Log it and expose it in the checklist.
- Cancel/debounce superseded checks, gate checks while a remap mutation is in flight, and allow at most one recovery prompt at a time. “Not Now” suppresses repeated foreground prompts until a later lifecycle trigger or a reasonable cooldown.
- Missing prompt buttons:
  - **Restore Now**: run the same functional install. If persistence is desired, also reinstall/bootstrap the LaunchAgent.
  - **Open Setup**: show the retained checklist at the remap area.
  - **Not Now**: preserve the expectation for a later launch/wake check.
- If the active mapping is present but desired persistence is invalid/unloaded, use the same prompt with **Repair Persistence** copy rather than claiming the mapping is already lost.

## 3. File-by-file ordered implementation changes

### 1. `app/Sources/LocalDictation/FirstRunChecks.swift`

- Keep `FirstRunChecks.evaluate()`, `SystemShortcutStatus`, and the two existing links as the system-conflict source of truth.
- Extract an internal pure evaluator accepting `appleDictationAutoEnable` and `symbolicHotKey164Enabled` so precedence and unknown behavior can be tested without reading host preferences.
- Keep symbolic hotkey 164 as the stronger signal. Preserve Siri `.unknown` and explicitly document that user confirmation is required for unknown status.
- Centralize/open the Keyboard and Siri URL constants through the onboarding action layer; continue returning the `Bool` from `NSWorkspace.open` so an open failure can be surfaced.
- Do not add private preference keys or GUI scripting.

### 2. `app/Sources/LocalDictation/MicKeyManager.swift`

- Add `MicKeyRemapStatus`: `.installed`, `.missing`, `.probeFailed(String)`. Make `remapStatus()` the authoritative query; retain `verifyRemap()` only as a compatibility convenience if existing call sites still need a Boolean.
- Replace the loose source/destination substring check in `userKeyMappingContainsOurRemap(_:)` with entry-wise parsing:
  1. JSON object/array;
  2. `PropertyListSerialization` for OpenStep plist output;
  3. normalize each entry’s hex/decimal `String`/`NSNumber` values through the existing `uint64(from:)` helper.
  Require source and destination in the same entry.
- Add `LaunchAgentStatus`: absent, invalid plist/reason, valid-but-unloaded, loaded. A successful `launchctl print gui/<uid>/<label>` means loaded even when the one-shot process state is “not running.”
- Validate the app-owned plist’s `Label`, `RunAtLoad`, and exact `ProgramArguments`; file existence alone is insufficient.
- Reuse #4’s shared command/process test seam where it is general enough, or add only a narrow injectable runner around `hidutil`/`launchctl`; do not create another server supervisor or launch-command resolver. Retain termination status/stdout/stderr for status probes. Mutation methods continue throwing useful `LocalizedError`s; non-mutating status methods return `.probeFailed`/invalid states instead of collapsing errors.
- After `installLaunchAgent()`, validate the plist and launchctl registration and throw a clear error if persistence is not healthy.
- Keep existing remap constants, `MicKeyInputMonitoringGuidance`, file location, and one-shot LaunchAgent mechanism.
- Do not change the existing whole-`UserKeyMapping` install/remove semantics in this issue; preserving arbitrary third-party mappings is separate scope.

### 3. New `app/Sources/LocalDictation/Onboarding.swift`

Keep the feature together unless the implementation becomes unwieldy; split view/window into `OnboardingView.swift` only if needed.

- Define `SetupStepID`, app-specific status values, `SetupSnapshot`, and pure completion derivation.
- Define `SetupPreferences` with the versioned/named-suite keys and one-time legacy LaunchAgent seeding described above.
- Define exact settings links and displayed fallback paths:
  - Microphone: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone`
  - Accessibility: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility`
  - Input Monitoring: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent`
  - Dictation: existing `FirstRunChecks.dictationSettingsURL`
  - Siri: existing `FirstRunChecks.siriSettingsURL`
- Implement `OnboardingCoordinator`:
  - snapshot reads from `AudioCapture`, AX, `FirstRunChecks`, `MicKeyManager`, and preferences;
  - async microphone request followed by refresh;
  - AX prompt/deep-link followed by later activation refresh;
  - Input Monitoring deep-link and explicit confirmation;
  - remap install/test with optional persistence and partial-success error copy;
  - persisted Dictation/Siri confirmations;
  - guarded `finishSetup()`.
- On link failure, keep the row incomplete, display the manual System Settings path, and log the failure.
- Implement `OnboardingView` as the six ordered rows, status/error text, action controls, Refresh, and Finish Setup. Disable repeated actions while one is running.
- Implement `OnboardingWindowController` with one retained `NSWindow` and SwiftUI hosting controller. `show()` must reuse/raise the window and refresh, not create duplicate windows.

### 4. New `app/Sources/LocalDictation/RemapHealthMonitor.swift`

- Define pure `RemapHealthAssessment.evaluate(...)` for expected/persistence/status combinations.
- Implement debounced launch/wake/session-active checks with injectable delays or a thin scheduling seam for tests.
- Expose one callback to `AppDelegate` for a user-facing issue and one “mutation in progress” gate shared with `OnboardingCoordinator`.
- Use an onboarding-scoped `Logger` declared with the feature (or the shared logging facility after #4) for trigger, retry, assessment, suppression, and restore events. Do not modify `AppConfig`, duplicate #4’s structured server diagnostics, or log user text/unrelated preferences.

### 5. `app/Sources/LocalDictation/App.swift`

- Replace `AppPrefs.firstRunChecksCompleted`/`runFirstRunChecksIfNeeded()` and the startup mic request with the coordinator/window launch behavior.
- Retain `AppPrefs.playSoundsEnabled` as-is.
- Add a **Setup Checklist…** item to the **final** menu after #4 diagnostics, #2 mic-mode controls, #1 server lifecycle status, and #5 installed-app Launch at Login behavior have landed. It always reopens the same window; do not reorder or recreate those owners’ items.
- Route the microphone and Accessibility status rows to the checklist instead of ad-hoc permission alerts. Keep their terse live titles.
- Replace the current direct install menu action with the checklist entry point; keep **Remove mic-key remap** as an explicit escape hatch, but route removal through the coordinator so expectations and UI update atomically.
- Preserve #5’s installed-app `SMAppService.mainApp` implementation and keep it separate from remap persistence; one launches the packaged app, the other reapplies the HID mapping.
- Refresh checklist/remap state in `menuWillOpen`, setup-window activation, and `applicationDidBecomeActive`.
- Register NSWorkspace wake/session-active observers and forward them to `RemapHealthMonitor`.
- Present recovery alerts from the monitor with Restore/Repair, Open Setup, and Not Now actions. Never present one over the visible first-run checklist.
- Preserve #2’s Carbon press/release registration, press-to-toggle default, opt-in hold-to-talk, persisted mic-mode preference, pending/active input intent, and toggle-only dev/menu actions. Preserve #1’s idle/desired-running lifecycle and #4’s generation-safe, health-only supervisor/diagnostics. #3 must not add parallel preferences, intent state, launch resolution, readiness, diagnostics, or process supervision.

### 6. Existing shared `app/Tests/LocalDictationTests/…`

Add focused XCTest files to the test target created by #4. Reuse #4’s temporary-directory, fake-command/process, clock, and fixture conventions rather than creating a second harness:

- `FirstRunChecksTests.swift`: symbolic hotkey precedence, fallback, unknown, and Siri unknown.
- `MicKeyManagerParsingTests.swift`: JSON, current OpenStep/decimal output, hex values, multiple mappings, source/destination in different entries (must be false), malformed output.
- `LaunchAgentStatusTests.swift`: valid plist, wrong label/arguments/mapping, missing file, loaded vs valid-unloaded; use temporary files/injected process output, never the real user LaunchAgents directory.
- `SetupSnapshotTests.swift`: all per-step state mappings and every completion condition, including optional persistence and manual confirmations.
- `SetupPreferencesTests.swift`: incomplete close vs finish, version behavior, expected-active semantics, persistence default, legacy valid-agent seed; use a unique throwaway defaults suite.
- `RemapHealthAssessmentTests.swift`: no expectation, healthy, session-only missing, desired persistence missing/invalid, probe failure, and restoration/suppression policy.

### 7. `README.md`

- Replace the ad-hoc permission/install instructions with the ordered Setup Checklist flow while retaining manual paths/Makefile commands as troubleshooting.
- Document that reapply-at-login is recommended but optional, that session-only users will be asked to restore after a reboot, and that the app checks an expected mapping after launch/wake.
- State the Input Monitoring limitation honestly: successful set+readback is the functional test.
- Document **Setup Checklist…** menu re-entry and **Remove mic-key remap** disabling future restore prompts.

### No changes

- `app/Package.swift` (the shared test target is already owned by #4), `AppConfig.swift`, `server/pyproject.toml`, Python server source/scripts, `RealtimeClient.swift`, `ServerSupervisor.swift`, `TextInserter.swift`, caret/indicator files, and audio capture implementation beyond using its existing permission APIs.
- #4/#5’s `ServerLaunchCommand` resolver/diagnostic/readiness implementation, #2’s input preference/intent implementation, and #1’s desired-running idle scheduling.
- `PLAN.md` is historical architecture context and need not be rewritten for this feature.

## 4. Tests and manual verification mapped to acceptance criteria

| Acceptance criterion | Automated coverage | Required manual verification on target macOS |
|---|---|---|
| First launch (or until complete) shows ordered Mic → Accessibility → Input Monitoring → remap → Dictation/Siri checklist | `SetupPreferencesTests`: absent/old version auto-show predicate; close does not complete; guarded finish persists current version. `SetupSnapshotTests`: fixed step order and completion gates. | Clear only the named feature defaults domain, launch app, verify one window appears in order without an immediate mic TCC prompt. Close and relaunch: it reappears. Complete all steps, relaunch: it stays closed. |
| Every step opens the relevant pane or runs remap install | URL constant/action-routing tests plus remap parser/install result state tests. | Click each row on macOS 15+ and macOS 26 target: verify Microphone, Accessibility, Input Monitoring, Keyboard, and Apple Intelligence & Siri panes open. Click Install/Test and verify `hidutil property --get UserKeyMapping` contains the exact paired decimal/hex values. |
| Checklist reflects current grant/remap status and reopens from menu | `SetupSnapshotTests` cover every permission/remap/agent/conflict state. Window-controller test or focused coordinator test verifies repeated show reuses one controller and refreshes. | Change each TCC/system setting, return to app or click Refresh, and verify state changes. Select **Setup Checklist…** repeatedly and confirm one raised/refreshed window, not duplicates. Verify a healthy one-shot LaunchAgent is shown as loaded even though not running. |
| Missing expected remap after reboot is proactively prompted and restorable | `RemapHealthAssessmentTests` and scheduler/dedup tests cover expected vs not expected, login grace retries, wake, probe errors, persistence repair, Not Now, and one-alert gating. | Install with persistence, complete setup, remove only the active mapping to simulate loss, relaunch and verify restore prompt/action. Repeat across a real reboot. Sleep/wake; if the mapping survives there should be no prompt, and if manually removed before wake there should be one. Verify session-only install prompts to restore after reboot. Verify explicit Remove produces no later restore prompt. |
| Completing flow allows 🎤 dictation without system Dictation stealing key | Completion predicate tests require active remap plus Dictation/Siri resolution/confirmation and required permissions. Existing #2 tests remain authoritative for input semantics. | Complete checklist, focus TextEdit, and verify the default press-to-toggle mode starts/stops dictation without Apple’s Dictation/Siri UI. Switch to #2’s hold-to-talk mode and verify hold-to-start/release-to-stop. Repeat after reboot with persistence. Verify ⌥⌘D and the menu command remain toggle actions. |

Additional regression checks:

- Run the shared suite from #4 with `cd app && swift test`, then `swift build -c release`; do not create a separate onboarding test invocation/target.
- Existing Python lint/smoke tests need not be rerun for logic confidence because no server files change, but `make run` is required for the final end-to-end app check.
- Deny microphone once, verify the row shows Denied and opens Settings rather than repeatedly requesting.
- Leave Accessibility denied and verify Finish Setup remains disabled and existing dictation refusal remains intact.
- Make `hidutil` set ineffective/deny Input Monitoring, verify the UI reports likely Input Monitoring rather than “installed.”
- Corrupt a copy of the LaunchAgent plist in a test fixture; production manual testing should repair through UI rather than hand-editing the live file unless explicitly desired.

## 5. Races, edge cases, failure behavior, and observability

### Races/lifecycle

- **Login race:** app launch and RunAtLoad can occur concurrently. Use delayed retries before declaring the expected map missing.
- **Wake/HID race:** wait briefly after wake/session activation; a transient empty property must not immediately produce a modal.
- **Concurrent install/check:** one shared mutation flag prevents a monitor read/alert between `hidutil --set`, readback, plist write, and bootstrap.
- **Duplicate lifecycle events:** cancel/debounce prior checks and gate prompt presentation. Returning from System Settings may generate several activation/menu events.
- **Checklist vs recovery alert:** the visible/incomplete checklist is the recovery UI; do not stack a modal on it.
- **Permission prompt timing:** AX prompting is asynchronous and microphone completion is callback-based. Refresh only after callbacks/activation; never optimistically mark a step complete.
- **User removes while a check sleeps:** re-read `expectedActive` immediately before presenting or restoring.
- **Quit during pending check/action:** cancel monitor tasks and remove workspace observers. Do not start a restore during termination.

### Edge/failure behavior

- Microphone `.restricted` remains blocked with explanatory copy; no fake recovery action.
- Accessibility or microphone revocation after historical completion is reflected on menu/checklist re-entry but does not erase the version marker.
- Input Monitoring is shown as manually reviewed plus functionally tested by remap, never as an authoritative TCC status.
- Siri remains manual/unknown. No private defaults or UI automation is introduced.
- A remap probe process failure is distinct from a genuinely absent mapping and produces no misleading restore alert.
- A successful active remap plus failed LaunchAgent install is a visible partial success. If persistence is selected, setup is incomplete until repaired; the user may unselect persistence and finish session-only.
- A loaded one-shot agent in `state = not running` is healthy. File-valid but unloaded is repairable, not “installed.”
- If a settings URL cannot open, show the exact manual path and retain the incomplete status.
- Existing `hidutil` operations replace/clear all `UserKeyMapping` entries. This plan intentionally does not broaden #3 into merging third-party mappings; state this limitation in failure copy if relevant.
- If System Settings data and manual confirmation disagree, preserve both facts in UI; manual confirmation controls completion because the probes are best-effort.

### Observability

- Use a feature-local onboarding log category through the logging conventions already established by #4. Log auto-show reason/version, snapshot status names (not raw unrelated preferences), action starts/results, exact remap/agent status, lifecycle trigger, retry number, suppressed prompt reason, and restore/repair outcome.
- Keep remap/onboarding failures actionable in the checklist/alert; Console must not be the only place to discover a failed remap or LaunchAgent bootstrap. Do not copy, wrap, or reinterpret #4’s structured server launch diagnostics.
- Do not log permission database contents, audio, transcript data, server stderr, launch commands, or server readiness as part of this issue.

## 6. Dependencies/conflicts with issues #1–#5 and landing order

All five feature branches pointed at the same initial commit during planning. Recommended serial landing order is **#4 → #5 → #2 → #1 → #3**; implementation planning below assumes that order:

1. **#4 — portable server path and in-app errors**
   - Owns the first/shared Swift test target and common fixtures.
   - Owns portable resolution, structured server diagnostics, `/health`-200-only readiness, generation-safe process supervision/test seams, and general `ServerLaunchCommand(executableURL, argumentPrefix, source)`.
   - #3 reuses its test target/logging conventions and does not add resolver, readiness, diagnostics, or supervisor layers.
2. **#5 — distributable `.app`**
   - Consumes/extends #4’s resolver/supervisor; it must not implement a duplicate resolver.
   - Owns `.app` assembly, self-contained Python runtime, signing, Info.plist/privacy usage strings, packaging verification, stable bundle ID `com.omcdowell.LocalDictation`, and installed-app `SMAppService` behavior.
   - Its packaged launch command is `Contents/Helpers/LocalDictationServer/bin/python3` plus `["-I", "-B", "-u", "-m", "local_dictation_server.server"]`; never `Resources/server` or a packaged console script.
   - #3 relies on this stable TCC/defaults identity and final installed-app behavior.
3. **#2 — hold-to-talk mic key**
   - Owns Carbon key press/release delivery, the persisted mic-mode preference, and explicit pending/active input intent.
   - Hardware mic-key default remains press-to-toggle; hold-to-talk is opt-in, and dev hotkey/menu remain toggle.
   - #3 only restores/checks the HID remap feeding F13 and must not duplicate mode keys, preference UI, Carbon handlers, or input-intent state.
4. **#1 — unload ASR after idle**
   - Layers idle scheduling and desired-running intentional stop/relaunch on #4’s supervisor and #2’s intent model.
   - Adds only any missing stop-reason/generation behavior; it does not perform a second broad supervisor/client rewrite.
   - #3 remains independent of desired-running/server readiness and should merge its menu/lifecycle observers around #1’s final state rather than replace it.
5. **#3 — guided onboarding**
   - Owns the ordered permission/remap/conflict checklist, versioned setup confirmations, remap expectation, LaunchAgent validation, wake/login remap health, recovery prompt, and menu re-entry.
   - Lands against the packaged identity and final menu. It uses `com.omcdowell.LocalDictation` for defaults while retaining LaunchAgent label `com.local-dictation.keyremap` for compatibility.
   - It adds tests/fixtures to #4’s shared target and does not duplicate #2 preferences or #4 diagnostics.

Cross-cutting readiness rule: `/health` 200 is the only readiness signal after #4. First-download waiting uses #4/#5’s output/activity-aware timeout behavior. No later issue—including #3—may reintroduce a brittle ready marker or an independent readiness timeout.

## 7. Incremental commit / tracer-bullet sequence

Start only after #4 → #5 → #2 → #1 has landed. Rebase onto that serial baseline before each conflict-heavy `App.swift` change. Every commit uses #4’s shared test target/fixtures and preserves #2 input intent, #1 desired-running behavior, and #4/#5 launch/readiness contracts.

1. **`test: define onboarding state in shared suite`**
   - Add the pure FirstRun evaluator and setup snapshot/completion/preferences tests to the existing `LocalDictationTests` target.
   - Use #4’s fixture conventions; do not edit `Package.swift` or create another harness.
2. **`feat: harden mic-key and launch-agent status probes`**
   - Add typed remap/agent statuses, paired-entry parser, plist validation, and loaded-one-shot-job detection.
   - Use the shared command/process seam where applicable, with only narrow `hidutil`/`launchctl` additions; adapt final menu status calls without touching server diagnostics or Carbon mode handling.
3. **`feat: add packaged-identity setup checklist tracer`**
   - Add `com.omcdowell.LocalDictation` versioned preferences, retained native window, ordered read-only rows, launch auto-show, Finish Later semantics, and **Setup Checklist…** re-entry in the final menu.
   - First end-to-end tracer: packaged app launch → window → refresh → persisted finish gate, while #1’s server may be stopped/warming independently.
4. **`feat: wire permission and system-settings actions`**
   - Remove startup mic request/ad-hoc first-run alert; add Mic/AX/Input/Dictation/Siri actions, confirmations, activation refresh, and actionable local failures.
   - Preserve #5 Info.plist/TCC identity and installed-app `SMAppService`; do not add packaging behavior here.
5. **`feat: install optional persistent mic-key remap from setup`**
   - Route install/remove through the coordinator, implement persistence toggle/partial success, expected-active storage, and menu status refresh.
   - Keep `com.local-dictation.keyremap` unchanged and leave #2’s mic-mode preference/input intent untouched.
6. **`feat: restore expected mic-key remap after launch or wake`**
   - Add lifecycle monitor, grace/retry/dedup policy, restore/repair alert, and shared-suite policy tests.
   - Merge observers around #1’s desired-running lifecycle; do not stop/start the ASR server.
7. **`docs: document guided setup and remap recovery`**
   - Update README, run the full shared Swift suite/build, run #5 packaging verification to catch identity/deep-link regressions, then execute the issue #3 acceptance matrix manually.

## 8. Explicit assumptions, decisions, and unresolved questions

### Decisions/assumptions

- The checklist is one native window, not a chain of alerts and not a new Settings architecture.
- The required order is Mic, Accessibility, Input Monitoring, remap, Dictation, Siri.
- LaunchAgent persistence is optional but defaults on/recommended.
- A verified session-only install still means the app expects the mapping active; after reboot it prompts to restore for that login.
- Explicit Remove is the only action that clears the active-remap expectation and suppresses future restore prompts.
- Input Monitoring status is not claimed from `CGPreflightListenEventAccess`; functional `hidutil` set/readback plus manual confirmation is used.
- Siri remains manual/unknown; no private API is acceptable.
- Historical `firstRunChecksCompleted` is intentionally ignored for the new versioned flow.
- The stable bundle ID/defaults suite established by #5 is `com.omcdowell.LocalDictation`.
- The existing remap LaunchAgent label and path remain `com.local-dictation.keyremap` / `~/Library/LaunchAgents/com.local-dictation.keyremap.plist` for compatibility; do not rename or migrate that job in #3.
- Server startup/download remains concurrent with onboarding and is not expanded by this issue. `/health` 200 remains the only readiness condition, and #3 does not alter #4/#5’s activity-aware first-download timeout behavior or `ServerLaunchCommand`.
- Existing whole-array `UserKeyMapping` mutation semantics remain unchanged.

### Genuinely unresolved

- None blocking. The exact System Settings deep links must be smoke-tested on each supported major macOS release; the implementation already has explicit manual-path fallbacks if Apple changes a route.
