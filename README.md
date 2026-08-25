# MDock Preview

Live window previews when you hover a Dock icon on macOS — the Windows‑taskbar
behaviour. Hover an app in the Dock and a floating panel shows a thumbnail of
each of its windows; click a thumbnail to switch to that window, or ✕ to close
it. It also adds a full **window switcher** (⌘Tab‑style). Runs as a menu‑bar
utility with no Dock tile.

## Requirements

- macOS 14+
- Two permissions (**System Settings › Privacy & Security**), requested on first
  launch via a Welcome guide:
  - **Accessibility** — pointer tracking over the Dock + switching/closing windows
  - **Screen Recording** — rendering the window thumbnails

## Features

- Hover previews, click‑to‑switch, per‑window close
- **Window switcher**: hold a shortcut + Tab to flip through every open window
  (Tab / Shift+Tab to cycle, release to switch, or click a tile). The shortcut
  is a preset — **⌘Tab** (replaces the system app switcher, default), **⌥Tab**,
  or **⌃Tab**
- Preview themes: System · Graphite · Frost · Vibrant
- Launch at login, optional hidden menu‑bar icon
- English + Vietnamese

## Build from source

Needs Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project MDockPreview.xcodeproj -scheme MDockPreview -configuration Release build
```

Or open `MDockPreview.xcodeproj` in Xcode and run.

## Release build (signed DMG)

Build a universal Release, sign with Developer ID, notarize + staple the app,
then build the styled installer image:

```bash
Scripts/make-dmg.sh   # needs the app pre-built, signed, notarized & stapled in dist/
```

`Scripts/make-dmg.sh` draws the backdrop ([`create-dmg-background.swift`](Scripts/create-dmg-background.swift)),
lays out the drag‑to‑Applications window and volume icon, then signs, notarizes,
and staples the DMG. It uses the `MFinderNotary` notarytool keychain profile.

## Notes

Uses the private `_AXUIElementGetWindow` API (like AltTab / yabai), so it ships
as a Developer ID–signed, notarized app **outside the Mac App Store**. macOS
reserves ⌘Tab for its own switcher; the app intercepts the real keystroke to
replace it — if that ever fails on your setup, switch to ⌥Tab in Settings.

Made with ❤️ for Maclife & Đồng Bọn.
