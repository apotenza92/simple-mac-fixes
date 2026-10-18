# Simple Mac Fixes

<img src="docs/assets/icon-stable-light.svg" alt="Simple Mac Fixes icon" width="96" />

A free app that fixes the small things about a Mac that annoy people, especially if you're used to Windows. Every fix has its own switch, and they're all on by default.

**[Download Simple Mac Fixes](https://apotenza92.github.io/simple-mac-fixes/)**

## What it fixes

- **Cut and paste files**: press Command-X to cut a file, then Command-V to move it to another folder.
- **Classic mouse wheel scrolling**: mice scroll in the traditional direction. Trackpads aren't affected.
- **Steady pointer speed** (off by default): the pointer moves the same distance however fast you move the mouse.
- **Maximize windows**: the green button makes a window fill the screen while keeping the Dock and menu bar. Hold Option when clicking for full screen.
- **Show app windows from the Dock**: click an app with several windows open to see them all and choose one.
- **Open Dock folders in Finder**: hold Option and click a folder in the Dock.
- **Volume and brightness keys everywhere**: the keys also work with more speakers, audio devices and external monitors.

## Install

Download it from the [download page](https://apotenza92.github.io/simple-mac-fixes/) and drag it to Applications, or install it with [Homebrew](https://brew.sh):

```sh
brew install --cask apotenza92/tap/simple-mac-fixes
```

The first time you open it, a short guide asks for the permissions it needs. Updates install automatically.

## Using it

Click the switch icon in the menu bar and choose **Settings** to turn fixes on or off. You can hide the icon in Settings; open Simple Mac Fixes again to get back to Settings.

It replaces [Macsimize](https://github.com/apotenza92/macsimize), [Dockmint](https://github.com/apotenza92/dockmint) and [Simple Mac Keyboard Control](https://github.com/apotenza92/simple-mac-keyboard-control), which close automatically. Apps that do the same job as a fix, like LinearMouse, also close while that fix is on.

## Permissions

- **Accessibility** (called Device Control on macOS 27): needed for every fix.
- **Input Monitoring**: only for brightness keys on a separate keyboard while a MacBook is closed.
- **System Audio Recording**: only for the volume keys on speakers and audio devices the Mac can't control. Sound stays on your Mac and is never recorded or saved.

## Build and run

```sh
scripts/run-dev.sh       # build, install to ~/Applications and launch; quits overlapping
                         # apps (Macsimize, LinearMouse…) and reopens them when dev quits
scripts/test.sh          # unit tests and app bundle checks
scripts/compile-icons.sh # after changing the icon artwork
```

Requires macOS 14.4 or later to run and Xcode 26 to build.
