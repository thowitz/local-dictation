# Feature implementation plans

Implementation-ready plans for the five open feature issues:

- [#1 — Unload ASR server after idle](issue-01-unload-after-idle.md)
- [#2 — Hold-to-talk mic key](issue-02-hold-to-talk.md)
- [#3 — Guided first-run onboarding](issue-03-guided-onboarding.md)
- [#4 — Portable server path and in-app errors](issue-04-portable-paths-and-errors.md)
- [#5 — Package as a distributable macOS app](issue-05-package-app.md)

## Recommended landing order

**#4 → #5 → #2 → #1 → #3**

1. **#4** establishes portable launch resolution, structured diagnostics, `/health`-only readiness, generation-safe supervision, and shared Swift test seams.
2. **#5** consumes that foundation to assemble and verify the self-contained app bundle.
3. **#2** establishes explicit pending/active input intent and F13 press/release semantics.
4. **#1** layers idle unload and cold relaunch onto the landed supervisor and input-intent models.
5. **#3** adds onboarding against the final bundle identity, menu structure, and remap behavior.

Rebase each feature branch onto the preceding landed feature before implementation; do not implement these plans independently against the initial commit and merge them wholesale.

## Shared integration contract

Read the domain language in [`CONTEXT.md`](../../CONTEXT.md) and the accepted decisions in [`docs/adr/`](../adr/) before implementation.

- Server launches are represented by `ServerLaunchCommand(executableURL, argumentPrefix, source)`.
- The packaged helper command is `Contents/Helpers/LocalDictationServer/bin/python3 -I -B -u -m local_dictation_server.server`.
- HTTP `200` from `/health` is the only readiness signal; stdout markers are diagnostic only.
- Stable app bundle ID and defaults suite: `com.omcdowell.LocalDictation`.
- Existing remap LaunchAgent label remains `com.local-dictation.keyremap` for compatibility.
- The speech runtime warms on application launch, may become dormant after inactivity, and is never adopted from an unknown listener.
- With opt-in hold-to-talk, releasing during warm-up withdraws the dictation request but does not cancel warm-up.
- A speech-runtime failure interrupts the session; it never reopens the microphone automatically.
- #4 creates the shared Swift test target and fixtures; later features extend them.
- #2 preserves press-to-toggle as the mic-key default, adds opt-in hold-to-talk, and keeps the dev hotkey and menu as toggle controls.
- #1 extends #4's supervisor and #2's input intent rather than replacing either.
