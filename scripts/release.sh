#!/usr/bin/env bash
# Build, zip, tag, and publish a GitHub release for Local Dictation.
#
# Requires a clean main branch in sync with origin/main, matching versions in
# Info.plist and server/pyproject.toml, a stable signing identity (not ad-hoc),
# and docs/release-notes/vX.Y.Z.md. Pass --dry-run to rehearse without publishing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SIGNING_IDENTITY_NAME="${SIGNING_IDENTITY_NAME:-Local Dictation Signing}"

log() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

usage() {
  echo "usage: $0 [--dry-run]" >&2
}

# --- Args --------------------------------------------------------------------

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $arg"
      ;;
  esac
done

# --- Preflight ---------------------------------------------------------------

log "Checking branch and working tree"
BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || die "releases must be cut from main (current branch: $BRANCH)"

STATUS="$(git -C "$REPO_ROOT" status --porcelain)"
[[ -z "$STATUS" ]] || die "working tree is dirty; commit or stash changes before releasing"

log "Fetching origin/main"
git -C "$REPO_ROOT" fetch origin main
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
ORIGIN_SHA="$(git -C "$REPO_ROOT" rev-parse origin/main)"
[[ "$HEAD_SHA" == "$ORIGIN_SHA" ]] || die "HEAD ($HEAD_SHA) != origin/main ($ORIGIN_SHA); push or pull before releasing"

if [[ "$DRY_RUN" == false ]]; then
  command -v gh >/dev/null 2>&1 || die "gh not found on PATH (needed to publish the GitHub release)"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run 'gh auth login' first"
fi

# --- Version resolution ------------------------------------------------------

log "Resolving version"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$REPO_ROOT/app/Resources/Info.plist")"
[[ -n "$VERSION" ]] || die "CFBundleShortVersionString empty in app/Resources/Info.plist"

PY_VERSION="$(grep -E '^version[[:space:]]*=' "$REPO_ROOT/server/pyproject.toml" \
  | head -n1 \
  | sed -E 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/')"
[[ -n "$PY_VERSION" ]] || die "could not extract version from server/pyproject.toml"
[[ "$VERSION" == "$PY_VERSION" ]] \
  || die "version mismatch: Info.plist=$VERSION pyproject.toml=$PY_VERSION"

TAG="v$VERSION"
log "Release tag: $TAG"

# Fail before the (slow) package build if the release notes are missing.
NOTES="$REPO_ROOT/docs/release-notes/$TAG.md"
[[ -f "$NOTES" ]] || die "missing release notes: $NOTES — write them before releasing"

if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  die "tag $TAG already exists locally"
fi
REMOTE_TAG="$(git -C "$REPO_ROOT" ls-remote --tags origin "refs/tags/$TAG")"
[[ -z "$REMOTE_TAG" ]] || die "tag $TAG already exists on origin"

# --- Signing identity guard --------------------------------------------------
# Refuse ad-hoc releases. Mirror package-app.sh's tolerant security(1) call
# under pipefail (exit 44 when the cert is absent).

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  log "Using CODESIGN_IDENTITY from environment: $CODESIGN_IDENTITY"
  [[ "$CODESIGN_IDENTITY" != "-" ]] \
    || die "CODESIGN_IDENTITY='-' is ad-hoc; releases require a stable signing identity"
else
  # `security find-certificate` exits 44 when the cert is absent; under
  # `set -o pipefail` that would abort the script, so tolerate it explicitly.
  _cert="$(security find-certificate -c "$SIGNING_IDENTITY_NAME" 2>/dev/null)" || true
  [[ -n "$_cert" ]] \
    || die "signing identity \"$SIGNING_IDENTITY_NAME\" not found; run 'make signing-identity' first"
  log "Found signing identity: $SIGNING_IDENTITY_NAME"
fi

# --- Build + verify ----------------------------------------------------------

log "Building package"
"$SCRIPT_DIR/package-app.sh"

log "Verifying package"
"$SCRIPT_DIR/verify-package.sh"

# --- Archive -----------------------------------------------------------------

ZIP="$REPO_ROOT/dist/LocalDictation-$TAG.zip"
log "Creating archive $ZIP"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$REPO_ROOT/dist/LocalDictation.app" "$ZIP"
(cd "$REPO_ROOT/dist" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
SHA256="$(awk '{print $1}' "$ZIP.sha256")"

# --- Publish -----------------------------------------------------------------

if [[ "$DRY_RUN" == true ]]; then
  log "[dry-run] would run:"
  echo "  git tag -a $TAG -m \"Local Dictation $TAG\""
  echo "  git push origin $TAG"
  echo "  gh release create $TAG $ZIP $ZIP.sha256 --title \"Local Dictation $TAG\" --notes-file $NOTES"
else
  log "Creating annotated tag $TAG"
  git -C "$REPO_ROOT" tag -a "$TAG" -m "Local Dictation $TAG"

  log "Pushing tag to origin"
  git -C "$REPO_ROOT" push origin "$TAG"

  log "Creating GitHub release"
  gh release create "$TAG" "$ZIP" "$ZIP.sha256" \
    --title "Local Dictation $TAG" \
    --notes-file "$NOTES"
fi

# --- Summary -----------------------------------------------------------------

echo
echo "==================================================================="
echo "Tag:                $TAG"
echo "Archive:            $ZIP"
echo "SHA-256:            $SHA256"
if [[ "$DRY_RUN" == true ]]; then
  echo "Published:          no (dry-run)"
else
  echo "Published:          yes"
  echo "View:               gh release view $TAG --web"
fi
echo "==================================================================="
