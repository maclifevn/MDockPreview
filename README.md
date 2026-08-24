# MDock Preview

Live window previews when you hover a Dock icon on macOS — the Windows‑taskbar
behaviour. Hover an app in the Dock and a floating panel shows a thumbnail of
each of its windows; click a thumbnail to switch to that window, or ✕ to close
it. Runs as a menu‑bar utility with no Dock tile.

## Requirements

- macOS 14+
- Two permissions (**System Settings › Privacy & Security**), requested on first
  launch via a Welcome guide:
  - **Accessibility** — pointer tracking over the Dock + switching/closing windows
  - **Screen Recording** — rendering the window thumbnails

## Features

- Hover previews, click‑to‑switch, per‑window close
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

## Notes

Uses the private `_AXUIElementGetWindow` API (like AltTab / yabai), so it ships
as a Developer ID–signed, notarized app **outside the Mac App Store**.

Made with ❤️ for Maclife & Đồng Bọn.
