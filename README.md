# Simple Mac Fixes

<img src="docs/assets/icon-stable-light.svg" alt="Simple Mac Fixes icon" width="96" />

Small fixes for the macOS behaviours that annoy people, especially if you're coming from Windows. One menu-bar app, good defaults, one switch per fix.

- **Cut and paste files in Finder**: ⌘X, then ⌘V moves files.
- **Traditional mouse scrolling**: wheel mice scroll like Windows; trackpads and the Magic Mouse keep your System Settings direction.
- **Maximize windows**: the green button or a title-bar double-click fills the screen without full screen. Drag the title bar to restore. Option-click the green button for full screen.
- **Dock shows app windows**: click an app in the Dock that has more than one window to pick one with App Exposé.
- **Volume and brightness keys everywhere**: media keys work with audio interfaces, USB DACs and external monitors.

Replaces [Macsimize](https://github.com/apotenza92/macsimize), [Dockmint](https://github.com/apotenza92/dockmint) and [Simple Mac Keyboard Control](https://github.com/apotenza92/simple-mac-keyboard-control).

## Required macOS permissions

- **Accessibility** (Device Control on macOS 27): every fix.
- **Input Monitoring**: only for brightness keys on an external keyboard with the MacBook closed.
- **System Audio Recording**: only for volume control on outputs without Mac volume. Audio stays on the Mac and is never recorded or stored.

## Build and run

```sh
scripts/run-dev.sh       # build, install to ~/Applications and launch; quits overlapping
                         # apps (Macsimize, LinearMouse…) and reopens them when dev quits
scripts/test.sh          # unit tests and app bundle checks
scripts/compile-icons.sh # after changing the icon artwork
```

Requires macOS 14.4 or later to run and Xcode 26 to build.
