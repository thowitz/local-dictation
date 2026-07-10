# Issue #5 implementation plan — package LocalDictation as a distributable macOS app

## Scope and outcome

Produce `dist/LocalDictation.app`, an Apple-Silicon, macOS 15+ menu-bar app that contains the Swift executable plus a relocatable CPython/MLX server runtime. A user can copy it to `/Applications`, launch it from Finder, download the model into their home-directory Hugging Face cache on first launch, grant permissions, install the mic-key remap, and enable `SMAppService.mainApp` without having the repository, `uv`, Python, or Xcode installed.

Keep the existing source-checkout workflow: `make server && make run` continues to execute the raw SwiftPM product and the repo's `server/.venv/bin/local-dictation-serve`.

Notarization, Developer ID distribution, DMG creation, auto-update, and bundling the 3.5 GB model remain out of scope.

This plan assumes the agreed serial order **#4 -> #5 -> #2 -> #1 -> #3**. At the start of #5, issue #4's portable resolver, `ServerLaunchCommand`, structured diagnostics, health-only readiness, generation-safe supervisor, test seams, and first shared Swift test target are already present. #5 consumes and extends that foundation; it does not recreate it.

---

## 1. Current state and code paths

### Swift application

- `app/Package.swift` defines only the `LocalDictation` executable target for macOS 15. It does not create an app bundle, copy resources, emit an `Info.plist`, or define tests.
- `app/Sources/LocalDictation/App.swift` has a custom `LocalDictationMain.main()` that runs `NSApplication` directly. `AppDelegate.applicationDidFinishLaunching(_:)` calls `NSApp.setActivationPolicy(.accessory)`, which hides the Dock icon at runtime, but there is no bundle-level `LSUIElement` metadata.
- The current SwiftPM product is only a linker-signed Mach-O. Inspection shows identifier `LocalDictation`, no bound `Info.plist`, no sealed resources, and no stable reverse-DNS bundle identifier.
- `AppDelegate.toggleLaunchAtLogin()` and `refreshLaunchAtLoginItem()` call `SMAppService.mainApp` unconditionally. The current alert already admits that this is not valid for a raw SwiftPM executable. It also treats every status except `.enabled` as simply off and does not handle `.requiresApproval` or `.notFound`.
- `AppConfig.compiledInRepoRoot` in `app/Sources/LocalDictation/AppConfig.swift` is the developer-specific `/Users/oxxxx/Code/local-dictation`. `AppConfig.resolvedServerExecutable` resolves only an explicit override or `<compiledInRepoRoot>/server/.venv/bin/local-dictation-serve`; its comment about deriving a repo path is not implemented.
- `ServerSupervisor.spawn()` in `app/Sources/LocalDictation/ServerSupervisor.swift` assumes one executable URL and appends `--port`, `--parent-pid`, and optional `--model`. It cannot represent “run bundled Python with `-m local_dictation_server.server`.”
- `ServerSupervisor.waitForReadiness()` currently accepts `sawReadyMarker` even though `server.py` prints `VOXMLX_READY` immediately before `uvicorn.run()` binds the socket. The code comment correctly says `/health` is the true readiness probe, but the supervisor can currently race ahead and connect too early.
- `ServerSupervisor.readinessTimeout` is a fixed 600 seconds. That can kill a legitimate first model download on a slower connection. Download percentages parsed by `parseDownloadProgress(in:)` already feed `ServerSupervisor.State.downloading` and then `DictationState.downloading`.
- `DictationController.bootstrap()` starts the server immediately, and `handleServerState(_:)` opens the persistent WebSocket only after the supervisor reports running. This lifecycle can remain intact once launch-command resolution and readiness are corrected.
- `MicKeyManager` in `app/Sources/LocalDictation/MicKeyManager.swift` runs the absolute system tools `/usr/bin/hidutil` and `/bin/launchctl`. Its persistent LaunchAgent runs `/usr/bin/hidutil`, not the app or server path, so packaging does not require a new helper or a changed remap plist. `MicKeyInputMonitoringGuidance.forCurrentApp()` will improve automatically once `Bundle.main` has a real name.

### Python server/runtime

- `server/pyproject.toml` exposes `local-dictation-serve = local_dictation_server.server:main`; production dependencies are `voxmlx`, `fastapi`, `uvicorn[standard]`, and `numpy`. `server/uv.lock` records the full native dependency graph.
- `server/src/local_dictation_server/server.py` imports MLX and voxmlx at module load, loads the default `mlx-community/Voxtral-Mini-4B-Realtime-6bit` model in `create_app()`, and only then creates `/health`. `main()` already supports every argument the supervisor needs and starts the parent-PID watchdog.
- Copying `server/.venv` is not a distributable solution. On the inspected machine:
  - `.venv/bin/python` is an absolute symlink into `~/.local/share/uv/python/...`;
  - `.venv/bin/local-dictation-serve` has an absolute checkout-specific shebang;
  - the venv is about 392 MB and contains many native `.so`/`.dylib` files;
  - MLX specifically requires `mlx/core*.so`, `mlx/lib/libmlx.dylib`, `mlx/lib/libjaccl.dylib`, and `mlx/lib/mlx.metallib` to stay together.
- The uv-managed CPython 3.13.13 installation is a python-build-standalone distribution. Its interpreter has `@executable_path/../lib` rpath and is designed to remain usable when its whole install directory is relocated.
- The model is not in the repo or venv. Hugging Face writes it to the user's cache (`~/.cache/huggingface` by default), which is writable and outside the signed app. `make model` already populates this same cache.

### Build/documentation

- `Makefile` builds the raw release executable and launches it directly. There is no `package`, package verifier, bundle metadata, icon, or signing step. `make run` checks only the repo venv entry point.
- `README.md` describes `LSUIElement` and Launch at Login as intended behavior, but there is no actual app bundle or install procedure. Its current quick start remains useful as the development workflow.
- At the inspected baseline there are no repository tests. Under the shared contract, #4 lands the first Swift test target and common resolver/supervisor fixtures before #5 begins; #5 adds cases to that target.

---

## 2. Chosen design and lifecycle changes

### 2.1 Self-contained sidecar strategy

Use a normal, relocatable CPython distribution inside the app rather than PyInstaller and rather than copying `.venv`.

At package time:

1. On an arm64 build host, use `uv python install --install-dir <staging> --no-bin 3.13.13` to fetch a pinned uv-managed/python-build-standalone CPython.
2. Resolve that managed interpreter with `UV_PYTHON_INSTALL_DIR=<staging> uv python find --managed-python --no-project --resolve-links 3.13.13` and copy its complete install root into the bundle.
3. From `server/`, export only the locked production dependencies with `uv export --frozen --no-dev --no-emit-project --format requirements.txt`.
4. Install/sync those requirements into the copied interpreter with `uv pip sync --python <bundled-python> --system --require-hashes --strict --link-mode copy`.
5. Install the local server package non-editably and without resolving a second dependency graph: `uv pip install --python <bundled-python> --system --no-deps --no-editable --link-mode copy <server-dir>`.
6. Remove generated console scripts from the bundled `bin/` except the Python executable and its relative `python`/`python3` symlinks; their staging-path shebangs are not a supported launch path.

The main app launches:

```text
Contents/Helpers/LocalDictationServer/bin/python3
  -I -B -u -m local_dictation_server.server
  --port 8471 --parent-pid <app-pid> [--model <override>]
```

`-I` prevents user site packages and `PYTHON*` variables from contaminating the server, `-B` prevents `.pyc` writes from modifying the signed app, and `-u` preserves immediate stdout/stderr progress. This retains ordinary Python package/resource semantics, including MLX's `.metallib`, and avoids freezer-specific hidden-import/resource failures.

No runtime dependency on `uv`, Homebrew, a system Python, or the checkout remains. Build-time `uv` and CLT requirements remain acceptable.

### 2.2 Bundle layout

Use this exact layout:

```text
dist/LocalDictation.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   └── LocalDictation
    ├── Resources/
    │   └── AppIcon.icns
    └── Helpers/
        └── LocalDictationServer/
            ├── bin/
            │   ├── python -> python3
            │   ├── python3 -> python3.13
            │   └── python3.13
            ├── lib/
            │   ├── libpython3.13.dylib
            │   └── python3.13/
            │       ├── ... standard library ...
            │       └── site-packages/
            │           ├── local_dictation_server/
            │           ├── mlx/lib/mlx.metallib
            │           └── ... locked production dependencies ...
            └── ... unpruned standalone-Python support files ...
```

Do not place executable code in `Contents/Resources`, do not put the model in the bundle, and do not create a second `.app` for the server.

### 2.3 Consume issue #4's shared launch contract

Issue #4 owns the general `ServerLaunchCommand` (`executableURL`, `argumentPrefix`, and `source`), portable resolution, structured attempted-path diagnostics, and resolver fixtures. It must already define the future packaged candidate exactly as:

```text
executableURL: <bundle>/Contents/Helpers/LocalDictationServer/bin/python3
argumentPrefix: ["-I", "-B", "-u", "-m", "local_dictation_server.server"]
source: bundleRuntime
```

It also owns override/Application Support/development-checkout precedence and the rule that a packaged app with a missing helper cannot fall through to a nearby checkout. In particular, there is no `Contents/Resources/server` console-script contract.

#5 supplies the helper at that already-defined path and adds packaged-context cases to #4's shared test target/fixtures. `ServerSupervisor.spawn()` continues consuming the command and appending `--port`, `--parent-pid`, and optional `--model`; #5 must not add a second resolver, a bundle-specific supervisor, or an alternative launch path.

### 2.4 Startup/model lifecycle on #4's supervisor

Issue #4 owns health-only readiness, generation-safe process supervision, process/clock/health test seams, output capture, structured failures, and restart diagnostics. `/health == 200` is the **only** transition to `ServerSupervisor.State.running`; `VOXMLX_READY` is diagnostic output only and must never be a readiness condition.

#5 extends that existing policy only where first model download needs it:

- Reuse #4's last-output/activity tracking and injected clock rather than adding another timer loop.
- Before download activity, keep #4's normal startup/load inactivity limit (10 minutes in the agreed policy).
- Once download activity is observed, permit up to two hours total while still failing after 10 minutes with no output/activity. Use #4's structured diagnostic to distinguish ordinary startup timeout from stalled download timeout.
- Preserve `downloading(percent:)`; per-file percentages may regress and are an activity/status hint, not aggregate progress.
- If #4 already lands this generic activity-aware behavior, #5 adds only packaged first-download regression tests and no `ServerSupervisor` rewrite.
- Interrupted downloads remain in Hugging Face's external cache and can resume. `make model`, raw runs, and bundled runs share the default cache because no path overrides `HF_HOME`.

The app continues bootstrapping the server at launch. Later #1 adds idle scheduling and desired-running intentional stop/relaunch on top of this supervisor and #2's explicit input intent; it must not replace the supervisor/client lifecycle.

### 2.5 App metadata, signing, and Launch at Login

Use stable metadata:

- `CFBundleIdentifier`: `com.omcdowell.LocalDictation`
- `CFBundleExecutable`: `LocalDictation`
- `CFBundlePackageType`: `APPL`
- `CFBundleName` / `CFBundleDisplayName`: `LocalDictation` / `Local Dictation`
- `CFBundleShortVersionString`: `0.1.0`
- `CFBundleVersion`: `1`
- `LSMinimumSystemVersion`: `15.0`
- `LSUIElement`: `true`
- `CFBundleIconFile`: `AppIcon`
- `NSMicrophoneUsageDescription`: concise dictation-specific copy
- `NSHighResolutionCapable`: `true`

Keep `NSApp.setActivationPolicy(.accessory)` as a harmless runtime reinforcement. Centralize the stable identity as `com.omcdowell.LocalDictation`: use it as the bundle identifier, logging subsystem fallback, and explicit `UserDefaults(suiteName:)` suite for both raw and packaged runs. Existing sound/first-run values move to that suite; later #2 and #3 must reuse it for their preferences/checklist state rather than create another store. Keep the existing `com.local-dictation.keyremap` LaunchAgent label for compatibility; it does not need to match the app identifier.

For a private/local package, sign all nested Mach-O files inner-first and then sign the outer app with ad-hoc identity `-`. Do not use `codesign --deep` as the signing mechanism; use it only as an additional verification. Signing happens after dependency installation, icon generation, and all file pruning. No hardened-runtime or library-validation-disabling entitlement is needed for this vertical slice. Allow `CODESIGN_IDENTITY` as a packaging-script override for a future real identity, but notarization remains separate.

> **Addendum (post-slice): stable identity for persistent Launch at Login.** Ad-hoc signing turned out to *break* Launch at Login: `SMAppService.mainApp` never persists because the ad-hoc designated requirement is a per-build cdhash, so `backgroundtaskmanagementd` can't re-match its stored login-item record and `.status` stays `.notFound`. `scripts/package-app.sh` now resolves a signing identity in order — (1) explicit `CODESIGN_IDENTITY`, (2) auto-detected self-signed cert `Local Dictation Signing` (signed by SHA-1; created one-time by `scripts/create-signing-identity.sh` / `make signing-identity`), (3) ad-hoc `-` with a loud warning. When the self-signed identity is used, the *outer* bundle is signed with an explicit designated requirement anchored to the certificate CN (`identifier "com.omcdowell.LocalDictation" and certificate leaf[subject.CN] = "Local Dictation Signing"`) so rebuilds and same-name cert regeneration keep existing registrations valid. `verify-package.sh` reports the identity/requirement (non-fatal, so ad-hoc CI builds still pass).

`SMAppService.mainApp` registers only the main app; the Python child remains supervised by the main app. Gate the menu action so raw `make run` builds and bundles not yet installed under `/Applications` cannot register a stale path. Show “install in /Applications first” in those cases. For an installed package:

- `.enabled`: checked; clicking unregisters;
- `.notRegistered`: unchecked; clicking registers;
- `.requiresApproval`: show approval-required state and open `SMAppService.openSystemSettingsLoginItems()`;
- `.notFound`: show an actionable error rather than presenting it as merely off.

Refresh this status whenever the menu opens so approval changes are visible. README instructions must copy the app first, launch the `/Applications` copy, grant permissions to that identity, and only then enable Launch at Login.

---

## 3. File-by-file ordered changes

### A. Integrate with the #4 baseline; do not duplicate it

1. **Consume #4's existing `ServerLaunchCommand` / resolver files.**
   - Do not add another resolver or change the command shape.
   - Confirm the #4 packaged candidate is exactly `Contents/Helpers/LocalDictationServer/bin/python3` plus `["-I", "-B", "-u", "-m", "local_dictation_server.server"]` and source `bundleRuntime`.
   - If the exact future candidate is missing, treat that as an incomplete #4 prerequisite and correct it in #4 ownership before starting #5; do not create a #5-local fallback or a `Resources/server` contract.

2. **Extend #4's shared Swift test target under `app/Tests/LocalDictationTests/`.**
   - Add packaged-command cases to the existing resolver fixture: exact executable and prefix, bundle paths containing spaces, packaged refusal to fall through when the helper is absent, and successful relocation.
   - Add first-download cases using #4's fake process/output/clock/health seams: active output extends the allowed window, 10 minutes of inactivity fails, the absolute cap fails, and a ready marker without `/health` never reaches running.
   - Reuse the shared temporary-filesystem/process fixtures. Do not add a second test target, standalone `swiftc` harness, or issue-specific fake supervisor.

3. **Update `app/Sources/LocalDictation/ServerSupervisor.swift` only if #4 lacks the agreed download extension.**
   - Reuse #4's output timestamps, generation tokens, clock, structured timeout diagnostics, and health probe.
   - Add only download-activity classification and the two-hour active-download cap/10-minute inactivity behavior.
   - Do not alter #4's generation ownership, stop/restart semantics, stderr tail, or `/health`-only transition.

4. **Add `app/Sources/LocalDictation/AppIdentity.swift` (or extend the identity helper established by #4).**
   - Define `bundleIdentifier/defaultsSuiteName = "com.omcdowell.LocalDictation"` and one shared `UserDefaults(suiteName:)` accessor.
   - Use this identity in raw and packaged builds so #2 and #3 inherit one stable preference namespace.

### B. Real app behavior and identity

5. **Update `app/Sources/LocalDictation/App.swift`.**
   - Replace direct `UserDefaults.standard` access for existing sound/first-run keys with the shared `com.omcdowell.LocalDictation` suite.
   - Add a small app-installation context used by Launch at Login gating.
   - Disable/relabel Launch at Login for raw binaries and packages outside `/Applications`.
   - Handle all `SMAppService.Status` cases and approval deep-link behavior.
   - Refresh login/remap/permission status on menu open (make `AppDelegate` an `NSMenuDelegate` and retain/set the delegate).
   - Keep `NSApp.setActivationPolicy(.accessory)`, current toggle hotkeys, remap actions, and `DictationController` transitions unchanged. #2, not #5, will add Carbon key release handling, opt-in hold-to-talk mode, persisted mic mode, and pending/active input intent while preserving press-to-toggle as the default; the dev hotkey and menu action remain toggle.
   - Do not register the Python runtime itself as a login item.

6. **Update logging identity in `app/Sources/LocalDictation/AppConfig.swift` and `TextInserter.swift` only as needed.**
   - Use `AppIdentity.bundleIdentifier` as the fallback subsystem; preserve #4's config/resolver and diagnostics code.
   - Do not alter insertion behavior.

7. **Add `app/Resources/Info.plist`.**
   - Include the exact metadata above, especially `LSUIElement`, stable bundle ID, minimum OS, icon, and microphone usage text.

8. **Add `app/Resources/AppIcon.svg`.**
   - Use a simple project-owned placeholder (for example, blue rounded square and white microphone), avoiding an SF Symbol redistribution dependency.
   - Generate all required iconset PNG sizes with `sips`, then `AppIcon.icns` with `iconutil` during packaging. Do not track generated PNG/iconset directories.

### C. Packaging and verification pipeline

9. **Add `scripts/package-app.sh`.**
   - `set -euo pipefail`; derive the repository root from the script, quote every path, and fail unless host architecture is arm64.
   - Build Swift release for arm64 and obtain its actual product path with `swift build --show-bin-path` rather than assuming `.build/release` internals.
   - Stage into `.package-build/` and publish atomically to `dist/LocalDictation.app` only after verification succeeds.
   - Install/copy pinned CPython 3.13.13 and install the frozen production requirements/local server package exactly as described above.
   - Preserve MLX package data and native libraries; do not prune the standalone runtime beyond unsafe generated entry-point scripts in the first implementation.
   - Assemble `Contents/{MacOS,Resources,Helpers}`, generate the icon, copy `Info.plist`, and preserve executable modes/symlinks.
   - Reject absolute or escaping symlinks in the staged runtime.
   - Sign every Mach-O in the helper runtime, then the main executable, then the app. Default to ad-hoc `-`; do not mutate any file after outer signing.
   - Print the output path, size, Python version, and signature identity.

10. **Add `scripts/verify-package.sh`.**
    - Validate required layout and executable bits.
    - Use `plutil` to assert bundle ID, executable, `APPL`, `LSUIElement=true`, minimum OS, microphone usage text, and icon declaration.
    - Verify the icon exists and `codesign --verify --strict --deep --verbose=2` succeeds.
    - Find every Mach-O, assert it contains arm64, assert it is signed, and reject non-system absolute dylib dependencies (especially `/Users/...` and Homebrew paths).
    - Reject absolute/escaping symlinks and grep text launchers/config for the original checkout path.
    - With a temporary empty `HOME` and a minimal `/usr/bin:/bin` `PATH`, run the bundled Python command through `... -m local_dictation_server.server --help`. This proves the normal package import graph, native MLX import, and relocation work without repo Python/uv while avoiding model download.
    - Do not launch the menu app or mutate login items in the automated verifier.

11. **Update `Makefile`.**
    - Keep `server`, `app`, and `run` semantics intact.
    - Add `package` -> `scripts/package-app.sh` and `package-check` -> verifier.
    - Reuse #4's Swift test target/`make test` entry; include the new packaged resolver and download-lifecycle tests there rather than adding `test-resolver` or a custom harness.
    - Add the packaging targets to `.PHONY` and `help`.
    - Extend `clean` to remove `.package-build/` and `dist/` but continue leaving the Hugging Face cache untouched.
    - Keep `make model` on the default Hugging Face cache so it primes both development and packaged execution.

12. **Update `.gitignore`.**
    - Ignore `/.package-build/`, `/dist/`, and generated iconsets/ICNS outputs while keeping `app/Resources/AppIcon.svg` and `Info.plist` tracked.

### D. Documentation

13. **Update `README.md`.**
    - Split build requirements (`uv`, CLT, arm64 Mac) from packaged runtime requirements (Apple Silicon, macOS 15+, network and roughly 4 GB free for first model download; no Python/uv/Xcode).
    - Make `make package` the distribution path and document `dist/LocalDictation.app`.
    - Give install steps using Finder or `ditto` to `/Applications`, then `open /Applications/LocalDictation.app`.
    - Tell users to grant Microphone, Accessibility, and Input Monitoring to the installed app, not the raw build. TCC grants remain executable/signature-specific, while preferences deliberately share the explicit `com.omcdowell.LocalDictation` defaults suite.
    - Document first-download state, cache location, resume behavior, and that `make model` primes the same cache.
    - Document the server resolution order and authoritative `serverExecutable` override implemented by #4, plus #5's exact bundled helper location; do not document a second package-only resolver.
    - Explain that Launch at Login is available only from the installed app and may require approval in General -> Login Items.
    - Preserve the development quick start (`make server`, `make app`, `make run`) and clarify that it intentionally uses the repo venv.
    - State that the package is arm64 and ad-hoc signed but not notarized; a quarantined copy transferred to another Mac may require the normal right-click Open/Open Anyway flow. Do not recommend disabling Gatekeeper globally.

### Files deliberately unchanged

- **`app/Package.swift`:** #4 owns the first shared Swift test target. #5 should use that target unchanged unless a test fixture file must be exposed; bundle assembly/resources remain external because SwiftPM does not produce this app bundle. Later #2, #1, and #3 reuse the same target and fixtures.
- **`server/pyproject.toml` and `server/uv.lock`:** no PyInstaller or runtime dependency is needed. Packaging exports the existing locked production graph and installs the local project non-editably.
- **`server/src/local_dictation_server/*.py`:** the existing module CLI, model loading, watchdog, health endpoint, and protocol already satisfy the sidecar contract.
- **`ServerExecutableResolver.swift` / #4 supervisor core:** consume #4's exact packaged command, precedence, structured diagnostics, generation safety, and test seams unchanged. Only the narrowly described download-timeout extension may touch `ServerSupervisor.swift`, and only if #4 did not already supply it.
- **`MicKeyManager.swift`:** retain the existing system-tool paths and `com.local-dictation.keyremap` LaunchAgent label; package-specific behavior comes from the real `com.omcdowell.LocalDictation` identity and signing.

---

## 4. Verification mapped to acceptance criteria

| Acceptance criterion | Automated verification | Required manual/on-target verification |
|---|---|---|
| `make package` produces a Finder-launchable `.app` | From a fresh clone on arm64: run `make package package-check`; assert layout, metadata, icon, arm64 slices, nested/outer signatures, safe symlinks and load paths, and bundled-server `--help` under empty `HOME`/minimal `PATH`. | Copy with `ditto` to `/Applications`, double-click in Finder, confirm one menu-bar icon, no Dock icon, menu opens, and app remains running. |
| App supervises ASR without checkout path | #5 cases in #4's shared Swift test target cover the exact bundled `ServerLaunchCommand`, relocation, and packaged refusal to fall back; verifier rejects checkout strings and runs the moved bundled runtime without repo tools. | Rename/move the checkout or test on a second account/Mac; launch `/Applications/LocalDictation.app`, confirm #4 diagnostics report `source=bundleRuntime`, server process command points inside the app, `/health` reaches 200, and one dictation session completes. |
| First launch downloads/loads model; permissions and remap work | Verifier proves imports and MLX resources without downloading. Shared supervisor tests use #4's fake output/clock/health seams to prove active-download extension, inactivity/absolute timeout, and `/health`-only readiness. Existing `make smoke` covers protocol/model with a cache. | On an Apple-Silicon user account with empty HF cache and no Python/uv/CLT, launch with network available; observe Downloading -> Starting/loading -> Ready, confirm app remains alive for a download longer than 10 minutes, then grant Microphone/Accessibility/Input Monitoring, install remap, verify `hidutil` mapping and `~/Library/LaunchAgents/com.local-dictation.keyremap.plist`, and dictate with the default toggle behavior. After #2, also verify the opt-in hold-to-talk mode. Interrupt/relaunch once to prove HF resume. |
| Launch at Login targets bundled app, not SPM binary | Resolver/app-install context checks cover raw vs installed-bundle gating; package signature verification satisfies the SMAppService signing prerequisite. | Confirm raw `make run` shows Launch at Login disabled with install guidance. From `/Applications`, register; handle `.requiresApproval` if shown; inspect General -> Login Items (and optionally `sfltool dumpbtm`) for `/Applications/LocalDictation.app`; log out/in and verify the menu app and its bundled child start. Unregister and verify it no longer launches. |
| README documents install and dev workflow remains viable | Check README/Make help list `package`, `package-check`, `server`, `app`, and `run`. Run #4's shared `make test`/Swift test target with #5's added cases. | In a fresh checkout with `make server`, run `make run`; confirm #4's raw-development resolution finds the repo venv, reaches Ready, and can dictate. Then repeat `make package` to ensure the two workflows do not overwrite each other. |

Additional release checks:

1. Run `make lint`, #4's shared `make test`/`swift test`, and `swift build -c release`.
2. Run existing `make smoke` against the repo server.
3. Start `Contents/Helpers/LocalDictationServer/bin/python3 -I -B -u -m local_dictation_server.server` with a cached model, wait for `/health`, and run `server/scripts/ws_smoke.py` against it. This is the full bundled-sidecar MLX/WebSocket check.
4. Inspect package size and confirm no model snapshot or `.venv` was copied.
5. After a dictation session, rerun `codesign --verify --strict --deep`; `-B` should prevent signature-breaking `.pyc` writes.
6. Test the app from a path containing spaces before installing, then from `/Applications`.

---

## 5. Races, edge cases, failure behavior, and observability

- **Marker/socket race:** #4 makes `/health` 200 the sole readiness condition. #5's shared regression case proves `VOXMLX_READY` alone cannot transition to running; do not add another readiness path.
- **Slow/stalled first download:** extend #4's activity-aware timeout through its existing output/clock seams: active download may run up to two hours, but 10 minutes without output fails. Keep the model's partial external cache for resume and use #4's structured timeout category.
- **Progress accuracy:** Hugging Face emits per-file percentages, so values may move backward. Treat them as activity/status only.
- **No network, disk full, corrupt cache, or MLX load failure:** the child exits or times out; #4's generation-safe restart/backoff and structured diagnostics apply and the app reaches `.error`. Reuse #4's bounded stderr tail/source/path menu detail; #5 adds no parallel error channel.
- **Missing/corrupt bundled runtime:** packaged resolution fails with the exact expected helper path and does not use a checkout. Package verification should catch this before distribution.
- **Configured override is stale:** fail explicitly because overrides are authoritative. Report the bad path and how to remove/update `serverExecutable`.
- **Port 8471 already occupied:** retain the current refusal to adopt an unknown process. A second app instance therefore fails visibly instead of attaching to another user's server.
- **App path contains spaces:** all build shell paths are quoted; runtime uses `Process` URLs/argument arrays.
- **Read-only/signed bundle:** `-B` prevents bytecode writes. Model/cache writes stay under the user's home directory. No server current directory may be assumed to be writable.
- **Native resources and dylibs:** preserve package-relative MLX data; verifier rejects host-specific load paths and checks every nested Mach-O's arm64 slice/signature.
- **Signing order:** any post-sign copy, prune, icon generation, or Python import without `-B` can invalidate the outer resource seal. Package script must assemble completely, sign inner-to-outer, then only verify/publish.
- **Ad-hoc identity/TCC:** the local package is code signed sufficiently for `SMAppService`, but rebuilding an ad-hoc app can cause macOS to request permissions again. A future stable Developer ID/notarized release is separate.
- **Quarantine:** local output is double-clickable; transfer/download can invoke Gatekeeper because this issue intentionally does not notarize. Document only Apple's normal Open/Open Anyway route.
- **Launch at Login path staleness:** prohibit registration before installation under `/Applications`. If an enabled app must be moved, unregister first, move, relaunch, and register again.
- **`SMAppService` approval changes:** refresh on menu open and distinguish `.requiresApproval`; never repeatedly call `register()` on an already registered service.
- **App update in place:** retain the same bundle identifier/path. Re-sign all nested code and outer bundle. Recheck login status after replacing the app.
- **Parent death:** launching Python directly preserves `--parent-pid`; the watchdog still exits the model process after the main app dies. Signing/packaging does not introduce a detached launcher process.
- **Remap persistence:** the LaunchAgent calls `/usr/bin/hidutil` and does not capture the bundle path. Its Input Monitoring/TCC behavior must be verified against the installed app identity.
- **Preferences and grants:** raw and packaged runs intentionally share `UserDefaults(suiteName: "com.omcdowell.LocalDictation")`; TCC grants remain tied to executable/signature identity and may need to be granted again for `/Applications/LocalDictation.app`.
- **Architecture/OS:** fail packaging on non-arm64. Metadata and SwiftPM continue to require macOS 15; no x86_64/universal claim is made.
- **Observability:** consume #4's source/path, child PID, generation, state, stderr-tail, health, and timeout diagnostics. #5 adds download classification where missing plus explicit package/signature verification stages. Do not log model tokens/credentials; existing transcript logging is outside this issue.

---

## 6. Dependencies, file ownership, conflicts, and landing order (#1-#5)

The recommended serial landing order is **#4 -> #5 -> #2 -> #1 -> #3**.

| Issue | Owns | Must consume / must not duplicate |
|---|---|---|
| **#4** | First shared Swift test target and fixtures; portable server resolution; structured diagnostics/stderr tail; `/health`-only readiness; generation-safe process supervision and test seams; general `ServerLaunchCommand(executableURL, argumentPrefix, source)`, including the future `Contents/Helpers/LocalDictationServer/bin/python3` command. | Must not package the runtime. Its resolver/supervisor are the single foundation for #5, #2, #1, and #3. |
| **#5** | Actual `.app` assembly; self-contained standalone Python/MLX helper at #4's path; Info.plist/icon; nested and outer signing; package verification; stable `com.omcdowell.LocalDictation` bundle/defaults identity; installed-app `SMAppService.mainApp`; first-download extension/tests on #4's activity seams. | Consumes #4's command/resolver/diagnostics/supervisor/test target. Must not add a resolver, broad supervisor rewrite, `Resources/server` entry point, Carbon hold behavior, or idle policy. |
| **#2** | Carbon key press/release handling; persisted mic-key mode; default mic-key **press-to-toggle** with opt-in hold-to-talk; explicit pending versus active input intent. Dev hotkey and menu remain toggle. | Reuses #5's defaults suite and #4's shared tests. Must not alter packaging or recreate diagnostics. |
| **#1** | Idle scheduling; desired-running state; intentional idle stop/relaunch layered onto #4's supervisor and #2's input intent. Add only missing stop-reason/generation behavior. | Must not perform a second broad supervisor/client rewrite. Reuses #4's generation/test fixtures and preserves #5's launch command. |
| **#3** | Guided onboarding and remap restoration against the final packaged identity/menu. | Uses `com.omcdowell.LocalDictation`, #5's installed app, #2's preference, and #4's diagnostics. Must not duplicate mic-mode preferences or server errors. |

### Conflict guidance

- **#4 -> #5:** `ServerExecutableResolver.swift`, `AppConfig.swift`, `ServerSupervisor.swift`, `Package.swift`, and the shared tests are #4-owned. Rebase #5 onto #4 and make only the narrow additions listed in this plan.
- **#5 -> #2:** both touch `App.swift` and defaults. #5 lands identity/SMAppService first; #2 then adds Carbon release and input intent while leaving package behavior untouched.
- **#2 -> #1:** both touch `DictationController` intent/lifecycle. #1 must schedule idle work against #2's explicit pending/active intent, not infer it from transient UI state.
- **#1 -> #3:** onboarding lands last against final server/menu/mic behavior and the installed bundle identity.
- Every later issue adds cases to #4's existing Swift test target and shared fake clock/process/filesystem fixtures; none independently creates another target or harness.

---

## 7. Incremental #5 commit / tracer-bullet sequence

**Prerequisite:** #4 is already green with its shared Swift tests, portable `ServerLaunchCommand`, structured diagnostics, generation-safe supervisor, and `/health`-only readiness.

1. **`test: pin packaged launch and download contracts`**
   - Add cases to #4's shared test target for the exact helper command, relocation/no-fallback behavior, ready-marker rejection, and activity-aware first-download deadlines.
   - Do not create new resolver/supervisor production types or a second test target.

2. **`build: assemble signed app with embedded Python server runtime`**
   - Add Info.plist, icon source, package script, exact `Contents/Helpers/LocalDictationServer` layout, uv-managed CPython installation, locked production package install, and ad-hoc nested/outer signing.
   - Tracer proof: #4's already-defined packaged command now exists; `make package` followed by bundled server `--help` succeeds under empty `HOME`/minimal `PATH`.

3. **`test: verify app bundle relocation and native sidecar`**
   - Add package verifier, Make targets, ignores, architecture/load-path/symlink/signature checks.
   - Tracer proof: move the package, run verifier, then start the bundled server with a cached model and pass `ws_smoke.py`.

4. **`fix: tolerate active first model downloads`**
   - If #4 does not already provide the full policy, add only download classification and the two-hour active cap/10-minute inactivity behavior through #4's output/clock/diagnostic seams.
   - Do not change health readiness or generation logic. Tracer proof: empty-cache activity extends startup; marker-only never becomes ready; inactivity fails structurally; cached launch reaches Ready promptly.

5. **`feat: establish packaged identity and installed launch at login`**
   - Add `com.omcdowell.LocalDictation` identity/defaults suite, switch existing preferences to it, gate raw/uninstalled builds, handle every `SMAppService` status, and refresh on menu open.
   - Leave current hotkeys as toggle; #2 preserves that default while adding opt-in hold-to-talk and Carbon release. Tracer proof: raw build cannot register; `/Applications` package registers and survives login.

6. **`docs: document packaged install and clean-machine assumptions`**
   - Update README and Make help; perform the complete acceptance matrix before closing #5.

Each commit leaves #4's `make run`, diagnostics, supervisor tests, and development resolution green. No intermediate commit redirects development to an incomplete bundle.

---

## 8. Explicit assumptions and decisions

- Target is Apple Silicon only and macOS 15+; no universal binary is promised.
- Bundle identifier and explicit defaults suite are both `com.omcdowell.LocalDictation`; initial app version/build is `0.1.0`/`1`.
- CPython is pinned to the observed compatible 3.13.13 standalone build for packaging; changing Python ABI requires rebuilding and rerunning all native-sidecar checks.
- The app contains Python and production wheels, but not `uv`, the development tools, the repo venv, or the model.
- The model remains in Hugging Face's default per-user cache so `make model`, raw runs, and bundled runs share it.
- A full standalone Python tree is preferred over aggressive pruning for the first distributable slice. Size optimization is follow-up work only after clean-machine MLX verification.
- A relocatable standard Python environment is preferred over PyInstaller because this dependency graph has dynamic imports plus MLX native libraries and `.metallib` resources; retaining package layout is simpler and less fragile.
- The packaged Python interpreter itself is the supervised sidecar executable; there is no shell wrapper, one-file extractor, XPC service, LaunchAgent, daemon, or second app bundle.
- Package builds are ad-hoc signed for private/local use. Developer ID, hardened-runtime policy, notarization, DMG, and Sparkle are out of scope.
- `SMAppService.mainApp` is offered only from the signed app installed under `/Applications`; the server helper is never independently registered.
- The `com.local-dictation.keyremap` LaunchAgent label remains unchanged for compatibility even though the app/defaults identity is `com.omcdowell.LocalDictation`.
- #4 owns `serverExecutable` override semantics and the general command abstraction. #5 uses the bundled interpreter only through #4's exact `ServerLaunchCommand`; it does not add an arbitrary command config surface.
- No server protocol, transcription, insertion, indicator, Carbon press/release, mic-mode, idle-unload, or model-selection behavior is broadened in #5.
- #2 subsequently adds opt-in hold-to-talk while preserving press-to-toggle as the mic-key default and retaining toggle for the dev hotkey/menu; #1 subsequently layers idle desired-running behavior on #2/#4; #3 subsequently uses the packaged identity/final menu.

### Genuinely unresolved questions

None required to implement this vertical slice. A real Developer ID identity/notarization policy is intentionally deferred, not an implementation blocker for #5.
