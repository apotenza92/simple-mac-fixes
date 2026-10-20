#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_dir="${HOME}/Applications"
installed_app="${install_dir}/Simple Mac Fixes Dev.app"
executable="${installed_app}/Contents/MacOS/SimpleMacFixes"

"${repo_dir}/scripts/build-app.sh"
# Reinstalling must not reopen the apps the previous launch quit.
"${repo_dir}/scripts/dev-other-apps.py" stop
# Keep the install path fixed: macOS keys permissions to it.
# A blanket pkill would also kill the process restoring disabled displays.
python3 - "${executable}" <<'PY'
import subprocess, sys, time
executable = sys.argv[1]
def running():
    commands = subprocess.check_output(['ps', '-axo', 'command='], text=True).splitlines()
    return [c for c in commands if c == executable or c.startswith(executable + ' ')]
commands = running()
if any('--display-prototype' in c for c in commands):
    raise SystemExit('Finish the bounded display prototype before reinstalling the development app.')
if any('--display-recovery' not in c for c in commands):
    subprocess.run(['osascript', '-e', 'tell application id "com.apotenza.SimpleMacFixes.dev" to quit'], check=True, timeout=15)
deadline = time.monotonic() + 12
while running() and time.monotonic() < deadline:
    time.sleep(.1)
if running():
    raise SystemExit('Development app or display recovery is still running; installation was not changed.')
PY
# Quit the release build, Macsimize, Dockmint, Keyboard Control, LinearMouse and the like so they
# don't act on the same clicks and keys; reopen them when the dev app quits.
"${repo_dir}/scripts/dev-other-apps.py" quit
mkdir -p "${install_dir}"
rm -rf "${installed_app:?}"
/usr/bin/ditto "${repo_dir}/build/Simple Mac Fixes Dev.app" "${installed_app}"
open -na "${installed_app}" --args "$@"
"${repo_dir}/scripts/dev-other-apps.py" watch "${executable}"
echo "Running ${installed_app}"
