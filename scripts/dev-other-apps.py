#!/usr/bin/env python3
"""Quit apps that overlap with Simple Mac Fixes while the dev build runs, then reopen them.

  quit   quit the running overlapping apps and remember them
  watch  wait in the background until the dev app exits, then reopen them
  stop   stop a waiting watcher without reopening anything (run-dev.sh does this before reinstalling)

The list of apps comes from ConflictingApp.known in Feature.swift.
"""
import json, os, re, signal, subprocess, sys, time
from pathlib import Path

repo_dir = Path(__file__).resolve().parent.parent
state_dir = Path.home() / 'Library/Caches/com.apotenza.SimpleMacFixes.dev'
state_file = state_dir / 'quit-apps.json'
watcher_pid_file = state_dir / 'watcher.pid'


def known_bundle_identifiers():
    source = (repo_dir / 'Sources/SimpleMacFixesCore/Feature.swift').read_text()
    return [i.lower() for i in re.findall(r'bundleIdentifier: "([^"]+)"', source)]


def running_apps():
    script = '''ObjC.import("AppKit");
JSON.stringify($.NSWorkspace.sharedWorkspace.runningApplications.js
  .filter(a => a.bundleIdentifier.js && a.bundleURL.js)
  .map(a => ({id: a.bundleIdentifier.js, path: a.bundleURL.path.js, pid: a.processIdentifier})))'''
    output = subprocess.check_output(['osascript', '-l', 'JavaScript', '-e', script], text=True)
    return json.loads(output)


def overlaps(bundle_identifier):
    # Matches beta and dev variants too, like ConflictingApp.conflicts.
    bundle_identifier = bundle_identifier.lower()
    return any(bundle_identifier == k or bundle_identifier.startswith(k + '.') for k in known_bundle_identifiers())


def load_state():
    try:
        return json.loads(state_file.read_text())
    except (FileNotFoundError, ValueError):
        return []


def save_state(paths):
    state_dir.mkdir(parents=True, exist_ok=True)
    if paths:
        state_file.write_text(json.dumps(paths))
    else:
        state_file.unlink(missing_ok=True)


def quit_apps():
    apps = [a for a in running_apps() if overlaps(a['id'])]
    if not apps:
        return
    pids = ' '.join(str(a['pid']) for a in apps)
    subprocess.run(['osascript', '-l', 'JavaScript', '-e', f'''ObjC.import("AppKit");
"{pids}".split(" ").forEach(p => {{
  const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(p));
  if (app.js) app.terminate;
}})'''], check=True, capture_output=True)
    still_running = set()
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        still_running = {a['pid'] for a in running_apps()} & {a['pid'] for a in apps}
        if not still_running:
            break
        time.sleep(.2)
    quit = [a for a in apps if a['pid'] not in still_running]
    for a in apps:
        status = 'still running, quit it yourself' if a['pid'] in still_running else 'quit'
        print(f"{Path(a['path']).stem}: {status}")
    paths = load_state()
    save_state(paths + [a['path'] for a in quit if a['path'] not in paths])


def stop_watcher():
    try:
        os.kill(int(watcher_pid_file.read_text()), signal.SIGTERM)
    except (FileNotFoundError, ValueError, ProcessLookupError):
        pass
    watcher_pid_file.unlink(missing_ok=True)


def dev_app_running(executable):
    commands = subprocess.check_output(['ps', '-axo', 'command='], text=True).splitlines()
    # Includes a --display-recovery helper, so apps reopen only once displays are restored.
    return any(c == executable or c.startswith(executable + ' ') for c in commands)


def watch(executable):
    if not load_state():
        return
    # Detach so the watcher outlives the terminal that ran run-dev.sh.
    if os.fork():
        return
    os.setsid()
    if os.fork():
        os._exit(0)
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    state_dir.mkdir(parents=True, exist_ok=True)
    watcher_pid_file.write_text(str(os.getpid()))
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))

    deadline = time.monotonic() + 30
    while not dev_app_running(executable) and time.monotonic() < deadline:
        time.sleep(.5)
    while dev_app_running(executable):
        time.sleep(1)
    # Ignore a stop request once reopening has started.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    for path in load_state():
        if Path(path).exists():
            subprocess.run(['open', '-g', path])
    save_state([])
    watcher_pid_file.unlink(missing_ok=True)
    os._exit(0)


if __name__ == '__main__':
    command = sys.argv[1] if len(sys.argv) > 1 else ''
    if command == 'quit':
        quit_apps()
    elif command == 'watch' and len(sys.argv) == 3:
        watch(sys.argv[2])
    elif command == 'stop':
        stop_watcher()
    else:
        raise SystemExit(__doc__)
