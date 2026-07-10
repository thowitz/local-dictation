#!/usr/bin/env bash
# Create a stable, self-signed code-signing identity for Local Dictation so that
# SMAppService.mainApp (Launch at Login) can persist its registration.
#
# Why this exists: an ad-hoc signature (`codesign --sign -`) has a designated
# requirement derived from the build's cdhash, which changes on every rebuild.
# macOS's backgroundtaskmanagementd can never re-match its stored login-item
# record, so Launch at Login silently falls back to `.notFound`. A stable cert
# gives the app a fixed identity + designated requirement the system remembers.
#
# This is a one-time, local setup. The certificate is self-signed and lives only
# in your login keychain — it is NOT a distribution identity and does not enable
# notarization or Gatekeeper trust. `scripts/package-app.sh` auto-detects it by
# name and signs with it.
#
# Idempotent: re-running is a no-op if the identity already exists.
#
# See docs/plans/issue-05-package-app.md §2.5 for the full rationale.
set -euo pipefail

SIGNING_IDENTITY_NAME="${SIGNING_IDENTITY_NAME:-Local Dictation Signing}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
VALIDITY_DAYS="${SIGNING_IDENTITY_DAYS:-3650}"

log() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "signing identity setup must run on macOS"
for tool in openssl security codesign; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found on PATH: $tool"
done

# Print the SHA-1 of the code-signing cert named $SIGNING_IDENTITY_NAME, if any.
sha1_of_identity() {
  security find-certificate -c "$SIGNING_IDENTITY_NAME" -Z "$KEYCHAIN" 2>/dev/null \
    | awk '/SHA-1 hash:/ {print $NF; exit}'
}

existing="$(sha1_of_identity || true)"
if [[ -n "$existing" ]]; then
  log "Signing identity already present: \"$SIGNING_IDENTITY_NAME\" (SHA-1 $existing)"
  log "Nothing to do — run 'make package' for a durably-signed app."
  exit 0
fi

[[ -t 0 ]] || die "run this interactively: it needs your login keychain password once"

log "Creating self-signed code-signing identity: \"$SIGNING_IDENTITY_NAME\""

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

KEY="$WORK/key.pem"
CERT="$WORK/cert.pem"
P12="$WORK/identity.p12"
# Transient passphrase to hand the key+cert to `security import`. Not stored.
P12_PASS="$(openssl rand -hex 16)"

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$KEY" -out "$CERT" -days "$VALIDITY_DAYS" \
  -subj "/CN=${SIGNING_IDENTITY_NAME}" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  >/dev/null 2>&1 \
  || die "openssl failed to generate the self-signed certificate"

# -legacy: OpenSSL 3.x's default PKCS#12 MAC/encryption is unreadable by macOS's
# security(1) importer ("MAC verification failed"); the legacy format imports.
openssl pkcs12 -export -legacy -inkey "$KEY" -in "$CERT" \
  -name "$SIGNING_IDENTITY_NAME" -out "$P12" -passout "pass:${P12_PASS}" \
  >/dev/null 2>&1 \
  || die "openssl failed to build the PKCS#12 bundle"

log "Importing into login keychain: $KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security \
  || die "security import failed"

# Let codesign use the private key without a GUI popup on every build. This step
# needs your login keychain password once (the same one you type at login); it
# is read straight into `security` and never stored. `set-key-partition-list`
# has no stdin option for -k, so the password is passed on its command line and
# is briefly visible in the process list (ps) for the duration of that one call.
echo
echo "One-time step: your login keychain password lets future builds sign without"
echo "a popup. It is passed directly to 'security' and is not stored anywhere"
echo "(though it is briefly visible in the process list during this one command)."
printf "Login keychain password: "
read -r -s KEYCHAIN_PW
echo
[[ -n "$KEYCHAIN_PW" ]] || die "no keychain password entered"

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null \
  || die "set-key-partition-list failed (wrong keychain password?)"

sha1="$(sha1_of_identity || true)"
[[ -n "$sha1" ]] || die "identity not found after import (unexpected)"

# Prove codesign can use the key non-interactively before we claim success.
cp /bin/echo "$WORK/smoke-bin"
codesign --force --timestamp=none --sign "$sha1" "$WORK/smoke-bin" >/dev/null 2>&1 \
  || die "codesign smoke test failed — key may still require an interactive unlock"

echo
log "Created signing identity \"$SIGNING_IDENTITY_NAME\" (SHA-1 $sha1)"
log "Next: run 'make package' — it auto-detects and signs with this identity."
