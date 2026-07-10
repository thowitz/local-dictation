#!/usr/bin/env bash
# Verify dist/LocalDictation.app (or a given app bundle path) is a correctly
# assembled, signed, relocatable package: layout, metadata, signatures,
# arm64-only native code, safe load paths/symlinks, no leaked checkout paths,
# and a working bundled Python/MLX import graph.
#
# Usage: scripts/verify-package.sh [path/to/LocalDictation.app]
#
# See docs/plans/issue-05-package-app.md for the full design rationale.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

# --- Resolve target app bundle ----------------------------------------------

if [[ $# -ge 1 ]]; then
  APP_ARG="$1"
  if [[ "$APP_ARG" == /* ]]; then
    APP_CANDIDATE="$APP_ARG"
  else
    APP_CANDIDATE="$PWD/$APP_ARG"
  fi
else
  APP_CANDIDATE="$REPO_ROOT/dist/LocalDictation.app"
fi

[[ -d "$APP_CANDIDATE" ]] || die "app bundle not found: $APP_CANDIDATE"
APP="$(cd "$APP_CANDIDATE" && pwd)"

for tool in plutil codesign lipo otool file perl; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found on PATH: $tool"
done

# --- Helpers -----------------------------------------------------------------

abspath() {
  perl -e 'use Cwd "abs_path"; my $p = abs_path($ARGV[0]); print $p if defined $p;' "$1"
}

find_macho_files() {
  local root="$1"
  find "$root" -type f -print0 | while IFS= read -r -d '' f; do
    if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then
      printf '%s\0' "$f"
    fi
  done
}

# --- 1: bundle layout --------------------------------------------------------

log "Checking bundle layout: $APP"

MAIN_EXECUTABLE="$APP/Contents/MacOS/LocalDictation"
BUNDLED_PYTHON="$APP/Contents/Helpers/LocalDictationServer/bin/python3"
INFO_PLIST="$APP/Contents/Info.plist"
ICON_ICNS="$APP/Contents/Resources/AppIcon.icns"

[[ -f "$MAIN_EXECUTABLE" ]] || die "missing main executable: $MAIN_EXECUTABLE"
[[ -x "$MAIN_EXECUTABLE" ]] || die "main executable is not executable: $MAIN_EXECUTABLE"
[[ -e "$BUNDLED_PYTHON" ]] || die "missing bundled interpreter: $BUNDLED_PYTHON"
[[ -x "$BUNDLED_PYTHON" ]] || die "bundled interpreter is not executable: $BUNDLED_PYTHON"

HELPER_LINK="$APP/Contents/Helpers/LocalDictationServer"
HELPER_BUNDLE="$APP/Contents/Helpers/LocalDictationServer.bundle"
[[ -d "$HELPER_BUNDLE" ]] || die "missing Helpers/LocalDictationServer.bundle (physical runtime)"
[[ ! -L "$HELPER_BUNDLE" ]] || die "LocalDictationServer.bundle must be a real directory"
# Launch path may be a same-Helpers symlink onto the .bundle (codesign requires
# the .bundle extension for nested Helpers directories).
if [[ -L "$HELPER_LINK" ]]; then
  target="$(readlink "$HELPER_LINK")"
  [[ "$target" == "LocalDictationServer.bundle" ]] \
    || die "Helpers/LocalDictationServer symlink must point at LocalDictationServer.bundle (got: $target)"
elif [[ -d "$HELPER_LINK" ]]; then
  die "Helpers/LocalDictationServer must be the launch-path symlink to LocalDictationServer.bundle"
else
  die "missing Helpers/LocalDictationServer launch path"
fi
resolved_py="$(abspath "$BUNDLED_PYTHON" || true)"
case "$resolved_py" in
  "$HELPER_BUNDLE"/*) ;;
  *) die "bundled python3 resolves outside Helpers/LocalDictationServer.bundle: $resolved_py" ;;
esac

[[ -f "$INFO_PLIST" ]] || die "missing Info.plist: $INFO_PLIST"
[[ -f "$ICON_ICNS" ]] || die "missing app icon: $ICON_ICNS"
# Resources must not contain the Python runtime (or any other code tree).
[[ ! -e "$APP/Contents/Resources/LocalDictationServer" ]] \
  || die "Resources/LocalDictationServer must not exist (runtime belongs under Helpers)"
while IFS= read -r -d '' res_entry; do
  base="$(basename "$res_entry")"
  [[ "$base" == "AppIcon.icns" ]] || die "unexpected Contents/Resources entry (only AppIcon.icns allowed): $res_entry"
done < <(find "$APP/Contents/Resources" -mindepth 1 -maxdepth 1 -print0)

# Nested helper bundle must itself verify.
log "Verifying nested Helpers/LocalDictationServer.bundle signature"
codesign --verify --strict --verbose=2 "$HELPER_BUNDLE"

# --- 2: Info.plist metadata --------------------------------------------------

log "Checking Info.plist metadata"

plist_value() {
  plutil -extract "$1" raw -o - "$INFO_PLIST"
}

expect_plist() {
  local key="$1" expected="$2" actual
  actual="$(plist_value "$key")" || die "Info.plist missing key: $key"
  [[ "$actual" == "$expected" ]] || die "Info.plist $key=$actual, expected $expected"
}

expect_plist "CFBundleIdentifier" "com.omcdowell.LocalDictation"
expect_plist "CFBundleExecutable" "LocalDictation"
expect_plist "CFBundlePackageType" "APPL"
expect_plist "LSUIElement" "true"
expect_plist "LSMinimumSystemVersion" "15.0"
expect_plist "CFBundleIconFile" "AppIcon"

MIC_USAGE="$(plist_value "NSMicrophoneUsageDescription")" || die "Info.plist missing NSMicrophoneUsageDescription"
[[ -n "$MIC_USAGE" ]] || die "NSMicrophoneUsageDescription is empty"

# --- 3: outer bundle signature (no --deep) ----------------------------------
# Per-Mach-O verification below is the granular nested-code coverage; --deep
# mis-parses the Helpers CPython/Tcl tree as nested bundles.

log "Verifying outer bundle signature (no --deep)"
codesign --verify --strict --verbose=2 "$APP"

# --- 3b: signing identity / Launch-at-Login persistence (advisory) ----------
# Not fatal: an ad-hoc build is a valid package, it just can't persist Launch at
# Login (SMAppService.mainApp keeps resetting to .notFound because the ad-hoc
# designated requirement is a per-build cdhash). Surface the identity + DR so
# the persistence property is visible without failing ad-hoc/CI builds.

log "Signing identity (advisory — Launch at Login persistence)"
SIG_INFO="$(codesign -dvvv "$APP" 2>&1 || true)"
if grep -q "Signature=adhoc" <<<"$SIG_INFO"; then
  echo "note: app is AD-HOC signed — Launch at Login will not persist across rebuilds."
  echo "note: run scripts/create-signing-identity.sh (make signing-identity), then re-package."
else
  AUTH_LINE="$(grep -m1 '^Authority=' <<<"$SIG_INFO" || true)"
  DESIG_REQ="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p' || true)"
  [[ -n "$AUTH_LINE" ]] && echo "signed by: ${AUTH_LINE#Authority=}"
  [[ -n "$DESIG_REQ" ]] && echo "designated requirement: $DESIG_REQ"
fi

# --- 4: per Mach-O checks (arch, signature, load paths) ---------------------

log "Checking every Mach-O binary (arch, signature, load paths)"

check_macho() {
  local f="$1"

  if ! lipo -archs "$f" 2>/dev/null | grep -qw "arm64"; then
    die "not arm64: $f"
  fi

  if ! codesign --verify --verbose=2 "$f" >/dev/null 2>&1; then
    die "invalid/missing code signature: $f"
  fi

  while IFS= read -r dep_path; do
    [[ -n "$dep_path" ]] || continue
    # otool's first listed name is often the dylib's own LC_ID_DYLIB.
    [[ "$dep_path" == "$f" ]] && continue
    case "$dep_path" in
      @rpath/*|@executable_path/*|@loader_path/*|/usr/lib/*|/System/*|"$APP"/*) ;;
      /Users/*|/home/*|/opt/homebrew/*|/usr/local/*)
        die "host-specific load-path dependency in $f: $dep_path"
        ;;
      *)
        # Bare names, wheel-relocatable placeholders (e.g. /DLC/...), etc.
        ;;
    esac
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
}

macho_count=0
while IFS= read -r -d '' macho; do
  check_macho "$macho"
  macho_count=$((macho_count + 1))
done < <(find_macho_files "$APP")
[[ "$macho_count" -gt 0 ]] || die "found no Mach-O binaries under $APP"
log "Checked $macho_count Mach-O binaries"

# --- 5: no absolute/escaping symlinks ---------------------------------------

log "Checking for unsafe symlinks"
while IFS= read -r -d '' link; do
  target="$(readlink "$link")"
  if [[ "$target" == /* ]]; then
    die "absolute symlink in package: $link -> $target"
  fi
  resolved="$(abspath "$link" || true)"
  [[ -n "$resolved" ]] || die "broken symlink in package: $link -> $target"
  case "$resolved" in
    "$APP"/*) ;;
    *) die "symlink escapes app bundle: $link -> $target (resolved: $resolved)" ;;
  esac
done < <(find "$APP" -type l -print0)

# --- 6: no leaked build-host checkout path ----------------------------------

log "Checking for leaked repo-root path in packaged text files"
LEAKED="$(grep -rIl --fixed-strings -- "$REPO_ROOT" "$APP" 2>/dev/null || true)"
if [[ -n "$LEAKED" ]]; then
  echo "error: found repo-root path leaked into packaged text files:" >&2
  echo "$LEAKED" >&2
  exit 1
fi

# --- 7: bundled server import graph, no network/model download -------------

log "Running bundled server --help under an empty HOME and minimal PATH"
TMPHOME="$(mktemp -d)"
trap 'rm -rf "$TMPHOME"' EXIT

HELP_OUTPUT="$(mktemp)"
if ! HOME="$TMPHOME" PATH="/usr/bin:/bin" "$BUNDLED_PYTHON" -I -B -u -m local_dictation_server.server --help >"$HELP_OUTPUT" 2>&1; then
  cat "$HELP_OUTPUT" >&2
  rm -f "$HELP_OUTPUT"
  die "bundled server failed to import/run under an isolated HOME/PATH"
fi
rm -f "$HELP_OUTPUT"

echo "OK"
