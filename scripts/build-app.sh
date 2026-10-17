#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_dir}/scripts/xcode-env.sh"

channel="${SIMPLEMACFIXES_CHANNEL:-stable}"
if [[ "${SIMPLEMACFIXES_RELEASE_BUILD:-0}" == "1" ]]; then
    display_name="Simple Mac Fixes"
    bundle_identifier="com.apotenza.SimpleMacFixes"
    if [[ "${channel}" == "beta" ]]; then
        display_name+=" Beta"
        bundle_identifier+=".beta"
    elif [[ "${channel}" != "stable" ]]; then
        echo "Release channel must be stable or beta." >&2
        exit 1
    fi
else
    display_name="Simple Mac Fixes Dev"
    bundle_identifier="com.apotenza.SimpleMacFixes.dev"
fi
app_dir="${repo_dir}/build/${display_name}.app"

swift build --package-path "${repo_dir}" -c release --product SimpleMacFixes
build_dir="$(swift build --package-path "${repo_dir}" -c release --show-bin-path)"

rm -rf "${app_dir:?}"
mkdir -p "${app_dir}/Contents/MacOS" "${app_dir}/Contents/Resources" "${app_dir}/Contents/Frameworks"
icon_name="AppIcon"
if [[ "${SIMPLEMACFIXES_RELEASE_BUILD:-0}" == "1" && "${channel}" == "beta" ]]; then
    icon_name="AppIconBeta"
fi
# Compiled icons are committed; regenerate them with scripts/compile-icons.sh.
cp "${repo_dir}/Resources/CompiledIcons/${icon_name}/Assets.car" "${app_dir}/Contents/Resources/"
cp "${repo_dir}/Resources/CompiledIcons/${icon_name}/${icon_name}.icns" "${app_dir}/Contents/Resources/"
ditto "${repo_dir}/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "${app_dir}/Contents/Frameworks/Sparkle.framework"
ditto "${repo_dir}/Resources/Licenses" "${app_dir}/Contents/Resources/Licenses"
# Ship PermissionFlow's localized helper resources in the installed app.
ditto "${build_dir}/PermissionFlow_PermissionFlow.bundle" "${app_dir}/Contents/Resources/PermissionFlow_PermissionFlow.bundle"
cp "${build_dir}/SimpleMacFixes" "${app_dir}/Contents/MacOS/SimpleMacFixes"

plist="${app_dir}/Contents/Info.plist"
cp "${repo_dir}/Resources/Info.plist" "${plist}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ${icon_name}" "${plist}"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconName string ${icon_name}" "${plist}"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${display_name}" "${plist}"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${display_name}" "${plist}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${bundle_identifier}" "${plist}"
if [[ -n "${SIMPLEMACFIXES_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${SIMPLEMACFIXES_VERSION}" "${plist}"
fi
if [[ -n "${SIMPLEMACFIXES_BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${SIMPLEMACFIXES_BUILD_NUMBER}" "${plist}"
fi
if [[ "${SIMPLEMACFIXES_RELEASE_BUILD:-0}" == "1" ]]; then
    # Updates stay off until the release pipeline provides a signing key and feed.
    if [[ -n "${SIMPLEMACFIXES_SPARKLE_PUBLIC_KEY:-}" ]]; then
        arch="$(uname -m)"
        [[ "$arch" != "x86_64" ]] || arch=x64
        /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${SIMPLEMACFIXES_SPARKLE_PUBLIC_KEY}" "${plist}"
        /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://raw.githubusercontent.com/apotenza92/simple-mac-fixes/main/appcasts/${channel}-${arch}.xml" "${plist}"
    fi
fi
printf 'APPL????' > "${app_dir}/Contents/PkgInfo"

# A stable signing identity keeps permissions across rebuilds.
identity="-"
available_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ -n "${SIMPLEMACFIXES_SIGNING_IDENTITY:-}" ]]; then
    identity="${SIMPLEMACFIXES_SIGNING_IDENTITY}"
elif [[ "${SIMPLEMACFIXES_RELEASE_BUILD:-0}" != "1" ]] && grep -q "Apple Development" <<<"${available_identities}"; then
    identity="$(sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' <<<"${available_identities}" | head -1)"
elif grep -q "Developer ID Application" <<<"${available_identities}"; then
    identity="$(sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' <<<"${available_identities}" | head -1)"
fi
if [[ "${SIMPLEMACFIXES_RELEASE_BUILD:-0}" == "1" && "${identity}" == "-" ]]; then
    echo "A release build requires a Developer ID or SIMPLEMACFIXES_SIGNING_IDENTITY." >&2
    exit 1
fi

framework="${app_dir}/Contents/Frameworks/Sparkle.framework"
# Sign nested helpers inside out; preserve Sparkle helper entitlements.
while IFS= read -r component; do
    codesign --force --sign "$identity" --options runtime --timestamp --preserve-metadata=entitlements "$component"
done < <(find "$framework/Versions/B" -depth \( -name "*.xpc" -o -name "*.app" -o -name Autoupdate \))
codesign --force --sign "$identity" --options runtime --timestamp "$framework"
if [[ "${identity}" != "-" ]]; then
    codesign --force --sign "${identity}" --options runtime --timestamp \
        --entitlements "${repo_dir}/Resources/SimpleMacFixes.entitlements" "${app_dir}"
else
    codesign --force --sign - --timestamp=none "${app_dir}"
fi

echo "Built ${app_dir}"
echo "Bundle identifier ${bundle_identifier}"
echo "Signed with ${identity}"
