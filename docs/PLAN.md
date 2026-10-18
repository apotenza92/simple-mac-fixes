# Plan

Simple Mac Fixes merges Macsimize, Dockmint (App Exposé only) and Simple Mac Keyboard Control into one app, and adds Finder cut and paste and traditional mouse scrolling.

## Done

- App shell: a menu bar icon with Settings and Quit (it can be hidden), a Settings window holding every switch, volume and brightness, launch at login, updates and permissions, setup guide, icon and menu glyph.
- Finder cut and paste, traditional mouse scrolling.
- Macsimize: green button and title-bar double-click maximize, drag-to-restore, Option-click full screen, with its tests.
- Dockmint: App Exposé on Dock click for apps with more than one window (no option). Full-screen windows are excluded from the count.
- Keyboard Control: volume, brightness, display enablement, HUD, with its tests.
- Sparkle wired in, but off until a signing key and feed exist.
- v0.0.1 released (stable only): Developer ID signed, notarized, Sparkle feeds on `main`, Homebrew cask `apotenza92/tap/simple-mac-fixes`.

## Next

1. **Hardware testing** of every fix (checklist in `AGENTS.md`).
2. ~~**Homebrew automation**~~ done: the tap publishes from the attested bundle on each release.
3. ~~**Website**~~ done: https://apotenza92.github.io/simple-mac-fixes/.
4. **Migration**:
   - Import settings from the old apps' defaults domains on first launch.
   - Explain in the setup guide that permissions must be granted again for the new app.
5. ~~**Retire the old apps**~~ done 2026-10-18: README and download-page notices, casks deprecated with `replacement_cask: "simple-mac-fixes"` (disabled by Homebrew on 2027-10-18), repos archived, the tap's KeyControl reconcile disabled. Old update feeds and pages still serve. Not done: a final in-app "moved" release through the old appcasts, so people who installed without Homebrew aren't told inside the old app (unarchive a repo to ship one).

## Open questions

- Finder cut feedback: a small HUD ("Cut 3 items") in the Keyboard Control HUD style.
- Uncommitted work in Macsimize (multi-display coordinate fix, log collection) and Keyboard Control (menu bar health monitor) was not ported; port it once committed.
- Verify the bundle identifiers of third-party conflicting apps other than LinearMouse and DockDoor in `Feature.swift`.
- Licence: Keyboard Control is MIT; Macsimize and Dockmint have no licence file. The repo currently carries Keyboard Control's MIT licence.
