#!/usr/bin/env bash
# Build LocalDictationInput.app (the input method) and, with --harness, the
# live input-method test harness. Bundles land in OUT (default app/.build/ime).
#
#   scripts/build-input-method.sh [--release] [--harness] [--out DIR] [--scratch DIR]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app"
CONFIG=debug
HARNESS=0
OUT="$APP_DIR/.build/ime"
SCRATCH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) CONFIG=release ;;
    --harness) HARNESS=1 ;;
    --out) OUT="$2"; shift ;;
    --scratch) SCRATCH=(--scratch-path "$2"); shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
SIGN_ID="${CODESIGN_IDENTITY:--}"

build() {
  (cd "$APP_DIR" && swift build -c "$CONFIG" "${SCRATCH[@]}" --product "$1" >&2)
  (cd "$APP_DIR" && swift build -c "$CONFIG" "${SCRATCH[@]}" --show-bin-path)
}

bundle() { # name executable plist
  local app="$OUT/$1" bin="$2" plist="$3"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin" "$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
  cp "$plist" "$app/Contents/Info.plist"
  xattr -cr "$app" 2>/dev/null || true
}

mkdir -p "$OUT"
BIN="$(build LocalDictationInputMethod)"
bundle LocalDictationInput.app "$BIN/LocalDictationInputMethod" "$APP_DIR/Resources/InputMethod-Info.plist"
cp "$APP_DIR/Resources/InputMethodIcon.tiff" "$OUT/LocalDictationInput.app/Contents/Resources/MenuIcon.tiff"
codesign --force --sign "$SIGN_ID" "$OUT/LocalDictationInput.app"
echo "$OUT/LocalDictationInput.app"

if [[ $HARNESS == 1 ]]; then
  BIN="$(build LocalDictationIMEHarness)"
  PLIST="$(mktemp)"
  cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>LocalDictationIMEHarness</string>
  <key>CFBundleIdentifier</key><string>com.omcdowell.LocalDictation.IMEHarness</string>
  <key>CFBundleName</key><string>LocalDictationIMEHarness</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
  bundle LocalDictationIMEHarness.app "$BIN/LocalDictationIMEHarness" "$PLIST"
  rm -f "$PLIST"
  codesign --force --sign "$SIGN_ID" "$OUT/LocalDictationIMEHarness.app"
  echo "$OUT/LocalDictationIMEHarness.app"
fi
