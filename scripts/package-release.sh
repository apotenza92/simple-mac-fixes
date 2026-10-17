#!/usr/bin/env bash
# Build one native architecture, sign, notarize, staple, and verify. Does not publish.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_dir}/scripts/xcode-env.sh"
: "${SIMPLEMACFIXES_SIGNING_IDENTITY:?Set a Developer ID Application identity}"
if [[ -n "${SIMPLEMACFIXES_NOTARY_KEY:-}" ]]; then
    : "${APPLE_NOTARYTOOL_KEY_ID:?Set the notary key ID}"
    : "${APPLE_NOTARYTOOL_ISSUER_ID:?Set the notary issuer ID}"
    notary_args=(--key "$SIMPLEMACFIXES_NOTARY_KEY" --key-id "$APPLE_NOTARYTOOL_KEY_ID" --issuer "$APPLE_NOTARYTOOL_ISSUER_ID")
else
    : "${SIMPLEMACFIXES_NOTARY_PROFILE:?Set a notarytool keychain profile}"
    notary_args=(--keychain-profile "$SIMPLEMACFIXES_NOTARY_PROFILE")
fi
case "$SIMPLEMACFIXES_SIGNING_IDENTITY" in
    'Developer ID Application:'*) ;;
    *) echo 'Packaging requires a Developer ID Application identity.' >&2; exit 1 ;;
esac
tag="${1:?Usage: scripts/package-release.sh vX.Y.Z[-beta.N] stable|beta}"
channel="${2:?Choose stable or beta}"
case "$(uname -m)" in arm64) arch=arm64 ;; x86_64) arch=x64 ;; *) exit 1 ;; esac
metadata="$(python3 "${repo_dir}/scripts/release/contract.py" "$tag" --channel "$channel" --arch "$arch")"
field() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1" <<< "$metadata"; }
export SIMPLEMACFIXES_RELEASE_BUILD=1 SIMPLEMACFIXES_CHANNEL="$channel"
export SIMPLEMACFIXES_VERSION="$(field version)" SIMPLEMACFIXES_BUILD_NUMBER="$(field build)"
"${repo_dir}/scripts/build-app.sh"
app="${repo_dir}/build/$(field name).app"
output="${repo_dir}/build/releases/$tag"
mkdir -p "$output"
upload="$(mktemp -d "${TMPDIR:-/tmp}/simplemacfixes-notary.XXXXXX")"
trap 'rm -rf "$upload"' EXIT
ditto -c -k --keepParent "$app" "$upload/submit.zip"
xcrun notarytool submit "$upload/submit.zip" "${notary_args[@]}" --wait --output-format json > "$upload/result.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r.get("status")=="Accepted" else "Notarization was not accepted")' "$upload/result.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"
asset="$(field asset)"
ditto -c -k --keepParent "$app" "$output/$asset"
(cd "$output" && shasum -a 256 "$asset" > "$asset.sha256")
cp "$upload/result.json" "$output/$asset.notary.json"
printf 'Verified package: %s\n' "$output/$asset"
