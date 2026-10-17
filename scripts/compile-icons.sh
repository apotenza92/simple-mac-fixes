#!/usr/bin/env bash
# Regenerate and compile the app icons. Run after changing generate-icon-assets.py;
# the compiled output is committed so ordinary builds do not need actool.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/scripts/xcode-env.sh"
python3 "$repo_dir/scripts/generate-icon-assets.py"
for icon in AppIcon AppIconBeta; do
    destination="$repo_dir/Resources/CompiledIcons/$icon"
    rm -rf "$destination"
    mkdir -p "$destination"
    xcrun actool "$repo_dir/Resources/$icon.icon" --compile "$destination" \
        --output-format human-readable-text --output-partial-info-plist "$destination/info.plist" \
        --app-icon "$icon" --include-all-app-icons --enable-on-demand-resources NO \
        --development-region en --target-device mac --minimum-deployment-target 14.4 --platform macosx
done
