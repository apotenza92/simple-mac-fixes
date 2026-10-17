# Simple Mac Fixes repository guide

## Product boundary

One native menu-bar app that fixes small macOS behaviours people (often Windows switchers) find annoying. Strong defaults; the menu is a list of on/off switches, and Settings holds only startup, updates, permissions and the setup guide.

Fixes, all on by default:

- **Cut and paste files in Finder**: ⌘X copies files and remembers the cut; the next ⌘V in Finder moves them with Finder's own ⌘⌥V. Text fields are never remapped.
- **Traditional mouse scrolling**: wheel mice scroll the traditional way; trackpads and the Magic Mouse keep the System Settings direction.
- **Maximize windows** (from Macsimize): the green button and a title-bar double-click maximize; dragging a maximized window's title bar restores its previous size under the cursor; Option-click on the green button still enters full screen.
- **Dock shows app windows** (from Dockmint, App Exposé only): clicking a running app's Dock icon shows App Exposé when the app has more than one window; with one window the click behaves normally. No sub-options. Full-screen windows are not counted because App Exposé never shows them.
- **Volume and brightness keys** (from Simple Mac Keyboard Control): software volume for fixed-volume outputs, DDC or software brightness for external displays, per-display enablement.

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
- Dock: click an app with one, two and zero windows; an app with a full-screen window plus one normal window; click the same icon again while App Exposé is open; drag an icon to reorder.
- Volume and brightness: follow `Tests/KeyboardControlManualTestPlan.md` (from Keyboard Control) for the affected hardware.

Do not run Dock or window automation unprompted: it changes the user's Dock and open windows.
