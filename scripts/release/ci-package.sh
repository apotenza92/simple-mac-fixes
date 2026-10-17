#!/usr/bin/env bash
# CI credential handling from Simple Mac Keyboard Control. Never run with shell tracing.
set -euo pipefail
tag="${1:?Usage: ci-package.sh TAG [stable|beta]}"
# Validate the tag/channel before importing credentials. No second argument means
# all channels authorized by the tag, packaged sequentially in this native job.
channels="$(python3 - "$tag" "${2:-}" <<'PY'
import sys
sys.path.insert(0, 'scripts/release')
from contract import parse_tag
channels = parse_tag(sys.argv[1])['channels']
if sys.argv[2]:
    if sys.argv[2] not in channels:
        raise SystemExit('Channel is not permitted by this release tag')
    channels = [sys.argv[2]]
print(' '.join(channels))
PY
)"
for variable in \
  APPLE_SIGNING_CERTIFICATE_P12_BASE64 \
  APPLE_SIGNING_CERTIFICATE_PASSWORD \
  APPLE_SIGNING_CERTIFICATE_SHA256 \
  APPLE_SIGNING_IDENTITY \
  APPLE_TEAM_ID \
  APPLE_NOTARYTOOL_KEY_ID \
  APPLE_NOTARYTOOL_ISSUER_ID \
  APPLE_NOTARYTOOL_KEY_P8_BASE64; do
  test -n "${!variable:-}" || { echo "::error::Missing $variable"; exit 1; }
done

SECURE_DIR="$(mktemp -d "$RUNNER_TEMP/simplemacfixes-release.XXXXXX")"
chmod 700 "$SECURE_DIR"
KEYCHAIN="$SECURE_DIR/signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
P12_PATH="$SECURE_DIR/signing.p12"
P8_PATH="$SECURE_DIR/AuthKey_${APPLE_NOTARYTOOL_KEY_ID}.p8"
CERT_PATH="$SECURE_DIR/leaf.pem"
ORIGINAL_KEYCHAINS=()
while IFS= read -r keychain; do
  keychain="${keychain#\"}"
  keychain="${keychain%\"}"
  ORIGINAL_KEYCHAINS+=("$keychain")
done < <(security list-keychains -d user | sed 's/^[[:space:]]*//')
cleanup() {
  if (( ${#ORIGINAL_KEYCHAINS[@]} )); then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" || true
  fi
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$SECURE_DIR"
}
trap cleanup EXIT

export P12_PATH P8_PATH
python3 - <<'PY'
import base64
import os
from pathlib import Path
for path_name, environment_name in (
    ("P12_PATH", "APPLE_SIGNING_CERTIFICATE_P12_BASE64"),
    ("P8_PATH", "APPLE_NOTARYTOOL_KEY_P8_BASE64"),
):
    path = Path(os.environ[path_name])
    path.write_bytes(base64.b64decode(os.environ[environment_name], validate=True))
    path.chmod(0o600)
PY
openssl pkcs12 -in "$P12_PATH" -clcerts -nokeys \
  -passin env:APPLE_SIGNING_CERTIFICATE_PASSWORD -out "$CERT_PATH"
chmod 600 "$CERT_PATH"
actual_fingerprint="$(openssl x509 -in "$CERT_PATH" -outform DER | shasum -a 256 | awk '{print toupper($1)}')"
expected_fingerprint="$(printf '%s' "$APPLE_SIGNING_CERTIFICATE_SHA256" | tr -cd '[:xdigit:]' | tr '[:lower:]' '[:upper:]')"
test "$actual_fingerprint" = "$expected_fingerprint"
subject="$(openssl x509 -in "$CERT_PATH" -noout -subject -nameopt RFC2253)"
[[ "$subject" == *"CN=$APPLE_SIGNING_IDENTITY"* ]]
[[ "$subject" == *"OU=$APPLE_TEAM_ID"* ]]

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12_PATH" -k "$KEYCHAIN" -P "$APPLE_SIGNING_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
export SIMPLEMACFIXES_SIGNING_IDENTITY="$APPLE_SIGNING_IDENTITY"
export SIMPLEMACFIXES_NOTARY_KEY="$P8_PATH"
for channel in $channels; do
    scripts/package-release.sh "$tag" "$channel"
done
