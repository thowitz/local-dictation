#!/usr/bin/env bash
# Assemble dist/LocalDictation.app: Swift release binary + a self-contained
# CPython/MLX helper runtime, signed ad-hoc (or with $CODESIGN_IDENTITY).
#
# See docs/plans/issue-05-package-app.md for the full design rationale.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_DIR="$REPO_ROOT/app"
SERVER_DIR="$REPO_ROOT/server"
DIST_DIR="$REPO_ROOT/dist"
DIST_APP="$DIST_DIR/LocalDictation.app"

STAGE="$REPO_ROOT/.package-build"
APP_STAGE="$STAGE/LocalDictation.app"
CONTENTS="$APP_STAGE/Contents"

PYTHON_VERSION="3.13.13"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

log() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || die "packaging must run on macOS"
[[ "$(uname -m)" == "arm64" ]] || die "packaging requires an Apple Silicon (arm64) host; got $(uname -m)"

for tool in swift uv sips iconutil ditto codesign file perl qlmanage install_name_tool; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found on PATH: $tool"
done

# --- Helpers -----------------------------------------------------------------

# Resolve a path through all symlinks, printing nothing (and returning
# non-zero) if any component is missing.
abspath() {
  perl -e 'use Cwd "abs_path"; my $p = abs_path($ARGV[0]); print $p if defined $p;' "$1"
}

# Print NUL-separated paths of every Mach-O file under $1.
find_macho_files() {
  local root="$1"
  find "$root" -type f -print0 | while IFS= read -r -d '' f; do
    if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then
      printf '%s\0' "$f"
    fi
  done
}

# --- 1-2: stage clean bundle skeleton ---------------------------------------

log "Cleaning staging directory"
rm -rf "$STAGE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Helpers"

# --- 3: build and copy Swift release binary ---------------------------------

log "Building Swift release executable"
(cd "$APP_DIR" && swift build -c release)
BIN_PATH="$(cd "$APP_DIR" && swift build -c release --show-bin-path)"
[[ -x "$BIN_PATH/LocalDictation" ]] || die "swift build did not produce $BIN_PATH/LocalDictation"
cp "$BIN_PATH/LocalDictation" "$CONTENTS/MacOS/LocalDictation"
chmod +x "$CONTENTS/MacOS/LocalDictation"

# --- 4: Info.plist -----------------------------------------------------------

log "Copying Info.plist"
cp "$APP_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

# --- 5: generate AppIcon.icns from the SVG source ---------------------------

log "Generating app icon"
ICON_SVG="$APP_DIR/Resources/AppIcon.svg"
[[ -f "$ICON_SVG" ]] || die "missing icon source: $ICON_SVG"

ICON_RENDER_DIR="$STAGE/icon-render"
ICONSET_DIR="$STAGE/AppIcon.iconset"
mkdir -p "$ICON_RENDER_DIR" "$ICONSET_DIR"
MASTER_PNG="$ICON_RENDER_DIR/master.png"

if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert --width 1024 --height 1024 "$ICON_SVG" -o "$MASTER_PNG"
else
  # qlmanage writes "<basename>.png" into the output dir; the exact name is
  # derived from the input filename, not something we choose.
  qlmanage -t -s 1024 -o "$ICON_RENDER_DIR" "$ICON_SVG" >/dev/null 2>&1 || true
  GENERATED_PNG="$ICON_RENDER_DIR/$(basename "$ICON_SVG").png"
  [[ -f "$GENERATED_PNG" ]] || die "qlmanage failed to rasterize $ICON_SVG (no rsvg-convert available either)"
  mv "$GENERATED_PNG" "$MASTER_PNG"
fi

# name:size pairs per Apple's iconset naming convention.
ICON_SPECS=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)
for spec in "${ICON_SPECS[@]}"; do
  name="${spec%%:*}"
  size="${spec##*:}"
  sips -z "$size" "$size" "$MASTER_PNG" --out "$ICONSET_DIR/$name" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$CONTENTS/Resources/AppIcon.icns"

# --- 6: bundled CPython runtime ---------------------------------------------
#
# Plan §2.2: runtime lives under Contents/Helpers/ (not Resources). codesign
# only treats a Helpers *directory* as nested code when it has a recognized
# bundle extension, so the physical tree is LocalDictationServer.bundle with
# Info.plist; a same-directory symlink exposes the #4 path
# Helpers/LocalDictationServer/bin/python3. Contents/Resources/ stays icon-only.

log "Installing bundled CPython $PYTHON_VERSION"
PY_STAGING="$STAGE/python-install"
mkdir -p "$PY_STAGING"
uv python install --install-dir "$PY_STAGING" --no-bin "$PYTHON_VERSION"

BUNDLED_PY="$(UV_PYTHON_INSTALL_DIR="$PY_STAGING" uv python find --managed-python --no-project --resolve-links "$PYTHON_VERSION")"
[[ -n "$BUNDLED_PY" ]] || die "uv python find did not resolve a managed interpreter"

# BUNDLED_PY looks like .../cpython-3.13.13-macos-aarch64-none/bin/python3.13
# The install root is the parent of that bin/ directory.
PY_ROOT="$(cd "$(dirname "$BUNDLED_PY")/.." && pwd)"

RUNTIME_ROOT="$CONTENTS/Helpers/LocalDictationServer.bundle"
HELPER_LINK="$CONTENTS/Helpers/LocalDictationServer"
mkdir -p "$(dirname "$RUNTIME_ROOT")"
log "Copying interpreter install root into $RUNTIME_ROOT"
ditto "$PY_ROOT" "$RUNTIME_ROOT"

# Minimal Info.plist so codesign treats this Helpers directory as a nested BNDL.
cat > "$RUNTIME_ROOT/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.omcdowell.LocalDictation.Server</string>
	<key>CFBundleName</key>
	<string>LocalDictationServer</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
EOF

# #4/#5 launch path (Helpers/LocalDictationServer/bin/python3) via in-Helpers symlink.
ln -sfn LocalDictationServer.bundle "$HELPER_LINK"
BUNDLED_PYTHON="$HELPER_LINK/bin/python3"
[[ -x "$BUNDLED_PYTHON" ]] || die "bundled interpreter missing after copy: $BUNDLED_PYTHON"

# --- 7: locked production dependencies + local server package --------------

log "Exporting locked production requirements"
REQS="$STAGE/requirements.txt"
(cd "$SERVER_DIR" && uv export --frozen --no-dev --no-emit-project --format requirements.txt -o "$REQS")
[[ -s "$REQS" ]] || die "uv export produced an empty requirements file"

log "Syncing production requirements into bundled interpreter"
# The copied uv-managed CPython ships an EXTERNALLY-MANAGED marker; this is our
# private relocatable runtime, not a system Python — allow the install.
uv pip sync --python "$BUNDLED_PYTHON" --system --break-system-packages \
  --require-hashes --strict --link-mode copy "$REQS"

log "Installing local server package (non-editable, no deps)"
uv pip install --python "$BUNDLED_PYTHON" --system --break-system-packages \
  --no-deps --no-editable --link-mode copy "$SERVER_DIR"

# --- 8: prune generated console-script shebangs -----------------------------

log "Pruning generated console scripts from $RUNTIME_ROOT/bin"
HELPER_BIN="$RUNTIME_ROOT/bin"
KEEP_NAMES=("python" "python3" "python3.13")
for name in "python" "python3" "python3.13"; do
  candidate="$HELPER_BIN/$name"
  [[ -e "$candidate" ]] || continue
  resolved="$(abspath "$candidate" || true)"
  [[ -n "$resolved" ]] || continue
  KEEP_NAMES+=("$(basename "$resolved")")
done

while IFS= read -r -d '' entry; do
  base="$(basename "$entry")"
  keep=0
  for keep_name in "${KEEP_NAMES[@]}"; do
    if [[ "$base" == "$keep_name" ]]; then
      keep=1
      break
    fi
  done
  if [[ "$keep" -eq 0 ]]; then
    rm -f "$entry"
  fi
done < <(find "$HELPER_BIN" -mindepth 1 -maxdepth 1 -print0)

# --- 8b: relocate install names + scrub staging absolute paths -------------
#
# uv's managed CPython records the staging prefix in libpython's LC_ID_DYLIB
# and in _sysconfigdata / pkgconfig / pip direct_url metadata. Rewrite those
# so the bundle is relocatable and does not embed the build checkout path.

log "Relocating bundled Python install names and scrubbing staging paths"
STAGING_PREFIX="$PY_ROOT"
# Intended on-disk prefix for sysconfig/pkg-config text only (runtime uses
# executable-relative layout; this must not contain the build checkout path).
RELOC_PREFIX="/Applications/LocalDictation.app/Contents/Helpers/LocalDictationServer"

LIBPYTHON="$RUNTIME_ROOT/lib/libpython3.13.dylib"
if [[ -f "$LIBPYTHON" ]]; then
  install_name_tool -id "@rpath/libpython3.13.dylib" "$LIBPYTHON"
fi

# Drop pip's direct_url.json — it records the absolute server/ checkout path.
find "$RUNTIME_ROOT/lib" -path '*/local_dictation_server*.dist-info/direct_url.json' -delete 2>/dev/null || true

# Rewrite staging prefix in text metadata (sysconfig, pkg-config, etc.).
while IFS= read -r -d '' textfile; do
  if grep -qF -- "$STAGING_PREFIX" "$textfile" 2>/dev/null; then
    # Prefer perl for in-place binary-safe substitution of absolute paths.
    STAGING_PREFIX="$STAGING_PREFIX" RELOC_PREFIX="$RELOC_PREFIX" perl -pi -e \
      'BEGIN { $from = $ENV{STAGING_PREFIX}; $to = $ENV{RELOC_PREFIX}; } s/\Q$from\E/$to/g' \
      "$textfile"
  fi
done < <(
  find "$RUNTIME_ROOT" -type f \( \
    -name '*.py' -o -name '*.pc' -o -name '*.txt' -o -name '*.json' \
    -o -name '*.h' -o -name 'Makefile' \
  \) -print0
)

# Fail early if the build checkout path still appears anywhere under the runtime.
if grep -rIl --fixed-strings -- "$REPO_ROOT" "$RUNTIME_ROOT" >/dev/null 2>&1; then
  echo "error: checkout path still present under bundled runtime after relocation:" >&2
  grep -rIl --fixed-strings -- "$REPO_ROOT" "$RUNTIME_ROOT" >&2 || true
  die "failed to scrub checkout path from bundled runtime"
fi

# --- 9: reject absolute or bundle-escaping symlinks -------------------------

log "Checking for unsafe symlinks under staged app"
while IFS= read -r -d '' link; do
  target="$(readlink "$link")"
  if [[ "$target" == /* ]]; then
    die "absolute symlink under staged app: $link -> $target"
  fi
  resolved="$(abspath "$link" || true)"
  [[ -n "$resolved" ]] || die "broken symlink under staged app: $link -> $target"
  case "$resolved" in
    "$APP_STAGE"/*) ;;
    *) die "symlink escapes app bundle: $link -> $target (resolved: $resolved)" ;;
  esac
done < <(find "$APP_STAGE" -type l -print0)

# --- 10: sign inner-first, then outer; never --deep to sign ----------------

log "Code-signing nested Mach-O binaries under Helpers/LocalDictationServer.bundle (identity: $CODESIGN_IDENTITY)"
while IFS= read -r -d '' macho; do
  codesign --force --sign "$CODESIGN_IDENTITY" "$macho"
done < <(find_macho_files "$RUNTIME_ROOT")

log "Code-signing Helpers/LocalDictationServer.bundle as nested BNDL"
codesign --force --sign "$CODESIGN_IDENTITY" "$RUNTIME_ROOT"

log "Code-signing main executable"
codesign --force --sign "$CODESIGN_IDENTITY" "$CONTENTS/MacOS/LocalDictation"

log "Code-signing outer app bundle"
codesign --force --sign "$CODESIGN_IDENTITY" "$APP_STAGE"

log "Verifying outer signature (no --deep; per-Mach-O coverage is in verify-package.sh)"
codesign --verify --strict --verbose=2 "$APP_STAGE"

# --- 11: atomic publish -----------------------------------------------------

log "Publishing to $DIST_APP"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_APP"
mv "$APP_STAGE" "$DIST_APP"
rm -rf "$STAGE"

# --- 12: summary -------------------------------------------------------------

PACKAGE_SIZE="$(du -sh "$DIST_APP" | awk '{print $1}')"
PYTHON_VERSION_OUTPUT="$("$DIST_APP/Contents/Helpers/LocalDictationServer/bin/python3" --version 2>&1)"

echo
echo "==================================================================="
echo "Packaged app:      $DIST_APP"
echo "Size:               $PACKAGE_SIZE"
echo "Bundled Python:     $PYTHON_VERSION_OUTPUT"
echo "Codesign identity:  $CODESIGN_IDENTITY"
echo "==================================================================="
