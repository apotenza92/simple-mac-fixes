#!/usr/bin/env bash

# Native layered .icon assets require Xcode 26 or later.
if ! xcrun xcodebuild -version 2>/dev/null | awk '/^Xcode / {exit !($2+0 >= 26)} END {if (NR == 0) exit 1}'; then
    xcode_app="$(python3 - <<'PY'
import glob, subprocess
for path in sorted(glob.glob('/Applications/Xcode*.app'), reverse=True):
    result = subprocess.run([path + '/Contents/Developer/usr/bin/xcodebuild', '-version'], capture_output=True, text=True)
    lines = result.stdout.splitlines()
    if result.returncode == 0 and lines and int(lines[0].split()[1].split('.')[0]) >= 26:
        print(path)
        break
PY
)"
    if [[ -z "${xcode_app}" ]]; then
        echo "Simple Mac Fixes requires Xcode 26 or later." >&2
        exit 1
    fi
    export DEVELOPER_DIR="${xcode_app}/Contents/Developer"
fi
