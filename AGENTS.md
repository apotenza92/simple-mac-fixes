# Simple Mac Fixes repository guide

## Product boundary

One native menu-bar app that fixes small macOS behaviours people (often Windows switchers) find annoying. Strong defaults; every switch and setting is in the Settings window, and the menu bar menu holds only Settings and Quit. The icon can be hidden; opening the app again (not a login launch) then shows Settings.

Fixes, all on by default:

- **Cut and paste files**: ⌘X in Finder is dropped and a fresh ⌘C is typed so Finder copies and the cut is remembered; the next ⌘V is replaced by Finder's own ⌘⌥V (Move Item Here). Editing the key press in place does not reach Finder's menus. The key's target process decides whether Finder is in front, since the workspace frontmost app lags. Text fields are never remapped.
- **Classic mouse wheel scrolling**: wheel mice scroll the traditional direction, three lines (30 points) per notch with wheel acceleration removed; high-resolution continuous wheels only change direction. Trackpads and the Magic Mouse keep the System Settings direction.
- **User-facing text** is plain language for non-technical people: say what they will see happen, no OS names, jargon or system references.
- **Maximize windows** (from Macsimize): the green button and a title-bar double-click maximize; dragging a maximized window's title bar restores its previous size under the cursor; Option-click on the green button still enters full screen.
- **Show app windows from the Dock** (from Dockmint, App Exposé only): clicking a running app's Dock icon shows App Exposé when the app has more than one window; with one window the click behaves normally. No sub-options. Full-screen windows are not counted because App Exposé never shows them.
- **Open Dock folders in Finder** (from Dockmint): only a plain Option-click on a Dock folder is consumed and hit-tested; every other click passes straight through.
- **Instant desktop switching** (adapted from InSpace / InstantSpaceSwitcher, MIT): a HID-level key tap on its own thread catches the user's own "Move left/right a space" shortcuts (read live from `com.apple.symbolichotkeys`, IDs 79–82) and its own ⌃⌥⌘1–9 (desktop N, counting desktops only like Mission Control) and ⌃⌥⌘Tab / ⌃⌥⌘` (next and previous space, wrapping, counting every space) ahead of the window server, and posts a synthetic Dock swipe fast enough to switch with no animation. The system's "Switch to Desktop N" shortcuts (IDs 118–133) are deliberately left alone, since macOS only offers them for desktops that exist. System shortcut settings are never modified, so nothing needs restoring. Never post past the first or last space (it can wedge the Dock).
- **Instant Dock**: sets `com.apple.dock` `autohide-delay` and `autohide-time-modifier` to 0 and restarts the Dock while the app runs; the saved originals are restored on quit, when switched off, and on the next launch after a crash. Needs no permission.
- **Main thread**: the active event taps run on the main thread, so it must never block. Accessibility queries from tap callbacks are capped at 0.3 s app-wide, the maximize tap only queries clicks within 120 points of a window's top (`WindowControlZone`), and Dock queries run on a background queue.
- **Volume and brightness keys** (from Simple Mac Keyboard Control): software volume for fixed-volume outputs, DDC or software brightness for external displays, per-display enablement.

The replaced apps (Macsimize, Dockmint/Docktor, Simple Mac Keyboard Control, including their beta and dev builds) are quit at launch and whenever they start. Other overlapping utilities in `ConflictingApp.known` (LinearMouse, DockDoor…) are quit the same way while the fix they overlap is on; Settings notes any that keep running.

Do not bring back other Dockmint actions, Macsimize's Maximize All/Restore All or full-screen mode setting, or anything Keyboard Control treats as out of scope (equalizers, per-app audio, device routing, custom shortcuts, contrast). Prefer a better default over a new setting.

## Modules

- `SimpleMacFixesCore`: Finder cut, mouse scrolling, the shared `EventTap`, feature catalog, update and setup policy.
- `MaximizeFeature`: Macsimize's interception and maximize engine; public surface is `GreenButtonMaximizeFeature`.
- `DockExposeFeature`: Dockmint's Dock hit-testing, window counting and App Exposé invocation; public surface is `DockAppExposeFeature`.
- `KeyboardControlFeature`: Keyboard Control's core, unchanged apart from identifiers.
- `SimpleMacFixes`: the app: `AppModel` (keyboard control, permissions, setup guide), `FeatureController` (the other fixes), menu, Settings, updates.

Ported code came from the last commits of each source repo (Macsimize 74303c0, Dockmint 2047a49, Keyboard Control 1fffbe8). Uncommitted work in those repos was not ported.

## Safety invariants

- Each feature owns its own event tap and starts, stops and fails independently. One feature must never block or crash another.
- Permissions are requested only where a feature needs them. Accessibility covers every fix; Input Monitoring is only for raw brightness keys; System Audio Recording only when a fixed-volume output needs software gain.
- When unsure, pass events through unchanged. Finder cut treats unknown focus as text. The Dock tap is listen-only, so the Dock always receives the native click.
- Event tap handlers stay fast: no file or network IO; AX queries bounded by messaging timeouts; window counting runs off the main thread.
- Keyboard Control's invariants still apply: the audio path is fail-open; the real-time audio callback allocates no memory, does no IO and takes no locks; software dimming leaves built-in displays alone and disappears on exit; display disabling requires a verified surviving display, arms recovery first and is never persisted.

## Verification

Run `scripts/test.sh` after application or build changes. `scripts/run-dev.sh` builds, installs to `~/Applications/Simple Mac Fixes Dev.app` and launches; keep that path and the `com.apotenza.SimpleMacFixes.dev` bundle identifier stable so permissions survive rebuilds. Do not kill the app with a blanket `pkill`: a `--display-recovery` helper may be restoring a display. `run-dev.sh` also quits the running apps listed in `ConflictingApp.known` (the old apps, LinearMouse and the like) and reopens them once the dev app exits, via `scripts/dev-other-apps.py`.

Behaviour that unit tests cannot prove needs a manual check on the real Mac, recorded honestly:

- Finder: cut/paste files between folders, the desktop and another volume; rename a file and use ⌘X/⌘V in the name; search field; Go to Folder; ⌘Z after a move; non-QWERTY layout.
- Scrolling: a wheel mouse, a free-spinning wheel (e.g. MX Master), the Magic Mouse and the trackpad, with natural scrolling on and off.
- Green button: click, Option-click, title-bar double-click, drag a maximized window to restore, multiple displays.
- Dock: Option-click a folder and a stack (opens Finder, no stack popup), plain-click it (stack as usual), Option-drag it; click an app with one, two and zero windows; an app with a full-screen window plus one normal window; click the same icon again while App Exposé is open; drag an icon to reorder.
- Volume and brightness: follow `Tests/KeyboardControlManualTestPlan.md` (from Keyboard Control) for the affected hardware.

Do not run Dock or window automation unprompted: it changes the user's Dock and open windows.

## Releases

Stable channel only (no beta for now). Add `release-notes/vX.Y.Z.md`, push it to `main`, then push the tag `vX.Y.Z`. `.github/workflows/release.yml` tests, signs with the Developer ID certificate, notarizes and staples on Apple silicon and Intel runners, uploads everything to a draft release and then publishes it (releases are immutable), then commits the Sparkle feeds (`appcasts/stable-{arm64,x64}.xml`) to `main`. The release carries an attested `homebrew-publication.tar.gz` (manifest, checksums and cask); `apotenza92/homebrew-tap` checks for it every 10 minutes (`reconcile-simple-mac-fixes.yml`), validates it against its `homebrew-products.json` entry and commits `Casks/simple-mac-fixes.rb`. Nothing is committed to the tap by hand.

Credentials live only in the `release-signing` and `sparkle-signing` environments (restricted to `v*` tags). The Sparkle private key is also in the release machine's login keychain under the Sparkle account `simple-mac-fixes`; its public key is in `scripts/build-app.sh`. Never print credentials or run `scripts/release/ci-package.sh` with shell tracing. Naming and build numbers come from `scripts/release/contract.py`.
