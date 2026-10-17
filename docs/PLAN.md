# Plan

Simple Mac Fixes merges Macsimize, Dockmint (App Exposé only) and Simple Mac Keyboard Control into one app, and adds Finder cut and paste and traditional mouse scrolling.

## Done

- App shell: Keyboard Control's menu bar UX with one switch per fix, Settings window (launch at login, updates, permissions, setup guide), setup guide, icon and menu glyph.
- Finder cut and paste, traditional mouse scrolling.
- Macsimize: green button and title-bar double-click maximize, drag-to-restore, Option-click full screen, with its tests.
- Dockmint: App Exposé on Dock click for apps with more than one window (no option). Full-screen windows are excluded from the count.
- Keyboard Control: volume, brightness, display enablement, HUD, with its tests.
- Sparkle wired in, but off until a signing key and feed exist.
- v0.0.1 released (stable only): Developer ID signed, notarized, Sparkle feeds on `main`, Homebrew cask `apotenza92/tap/simple-mac-fixes`.

## Next

1. **Hardware testing** of every fix (checklist in `AGENTS.md`).
2. **Homebrew automation**: the cask is committed to the tap by hand from the `homebrew-cask` artifact. Register the product in the tap's `homebrew-products.json` trusted publisher (it currently assumes a beta cask) or push with the tap token from the release workflow.
3. **Website** on GitHub Pages in the same style as the other apps.
4. **Migration**:
   - Import settings from the old apps' defaults domains on first launch.
   - Detect the old apps running; offer to quit them and move them to the Trash.
   - Explain in the setup guide that permissions must be granted again for the new app.
5. **Retire the old apps**:
   - Ship a final "moved to Simple Mac Fixes" release of each through its existing appcast.
   - Deprecate the old Homebrew casks, close issues, add README banners.
   - Archive the old repos a few weeks later, after confirming archived appcasts and Pages still serve.

## Open questions

- Finder cut feedback: a small HUD ("Cut 3 items") in the Keyboard Control HUD style.
- Uncommitted work in Macsimize (multi-display coordinate fix, log collection) and Keyboard Control (menu bar health monitor) was not ported; port it once committed.
- Verify the bundle identifiers of third-party conflicting apps other than LinearMouse and DockDoor in `Feature.swift`.
- Licence: Keyboard Control is MIT; Macsimize and Dockmint have no licence file. The repo currently carries Keyboard Control's MIT licence.
