#!/bin/bash
# Build the release disk image from the stapled dist/MDockPreview.app: a light
# drag-to-Applications installer window with a generated background and a volume
# icon, then sign, notarize, and staple the DMG itself so it opens with no
# Gatekeeper warning.
#
# The app must already be signed (Developer ID) AND notarized+stapled — see the
# steps in README / RELEASING. Requires a notary keychain profile (default
# MFinderNotary, an account/team credential shared with the MFinder project):
#   xcrun notarytool store-credentials MFinderNotary \
#     --apple-id you@example.com --team-id CF5PGH3KGK
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

APP="$ROOT/dist/MDockPreview.app"
PROFILE="${1:-MFinderNotary}"
SIGN_ID="${SIGN_ID:-Developer ID Application: Anh Tuan Vu Nguyen (CF5PGH3KGK)}"
[ -d "$APP" ] || { echo "error: $APP not found — build + stapler the app first." >&2; exit 1; }

if [ "${1:-}" = "--key" ]; then
    NOTARY_CREDS=(--key "$2" --key-id "$4" --issuer "$6")
else
    NOTARY_CREDS=(--keychain-profile "$PROFILE")
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VOLUME_NAME="MDock Preview ${VERSION}"
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    DMG="$ROOT/dist/MDockPreview-${VERSION}-preview.dmg"
else
    DMG="$ROOT/dist/MDockPreview-${VERSION}.dmg"
fi

# Requirements line for the backdrop, derived from the actual binary slices.
ARCHS_LINE="$(lipo -archs "$APP/Contents/MacOS/MDockPreview" 2>/dev/null || echo "")"
if echo "$ARCHS_LINE" | grep -q x86_64 && echo "$ARCHS_LINE" | grep -q arm64; then
    REQUIREMENTS="macOS 14+   ·   Apple silicon & Intel"
elif echo "$ARCHS_LINE" | grep -q arm64; then
    REQUIREMENTS="macOS 14+   ·   Apple silicon"
else
    REQUIREMENTS="macOS 14 or later"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mdock-dmg.XXXXXX")"
RW_DMG="$WORK_DIR/MDockPreview-rw.dmg"
BACKGROUND="$WORK_DIR/background.png"
MOUNT_DIR=""
MOUNT_DEVICE=""
MOUNTED=false

cleanup() {
    if [ "$MOUNTED" = true ]; then
        hdiutil detach "${MOUNT_DEVICE:-$MOUNT_DIR}" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "==> Verifying the signed app…"
codesign --verify --deep --strict "$APP"
# The payload must carry its own ticket so an offline first launch never trips
# Gatekeeper.
xcrun stapler validate "$APP" >/dev/null

echo "==> Drawing the installer background…"
swift Scripts/create-dmg-background.swift "$BACKGROUND" "$VERSION" "$REQUIREMENTS"

# Detach leftovers from an interrupted run so Finder can't target a clashing
# volume name and write the layout to the wrong image.
while IFS= read -r stale; do
    [ -n "$stale" ] || continue
    echo "    detaching leftover volume: $stale"
    hdiutil detach "$stale" -force >/dev/null 2>&1 || true
done < <(ls -d "/Volumes/${VOLUME_NAME}"* 2>/dev/null || true)

SIZE_MB=$(( $(du -sm "$APP" | cut -f1) + 60 ))
hdiutil create -volname "$VOLUME_NAME" -fs HFS+ -ov \
    -size "${SIZE_MB}m" "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
MOUNT_DEVICE="$(awk '/Apple_HFS/ {print $1}' <<<"$ATTACH_OUTPUT" | tail -1)"
MOUNT_DIR="$(sed -n 's/^.*Apple_HFS[[:space:]]*//p' <<<"$ATTACH_OUTPUT" | tail -1)"
MOUNTED=true
[ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ] || {
    echo "error: could not determine the mounted DMG path." >&2
    exit 1
}
ACTUAL_VOLUME="$(basename "$MOUNT_DIR")"

echo "==> Staging the installer window…"
ditto "$APP" "$MOUNT_DIR/MDockPreview.app"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir -p "$MOUNT_DIR/.background"
cp "$BACKGROUND" "$MOUNT_DIR/.background/background.png"

SETFILE="$(command -v SetFile || command -v setfile || true)"
if [ -n "$SETFILE" ]; then
    "$SETFILE" -a V "$MOUNT_DIR/.background"
fi

# Finder owns .DS_Store layout metadata, so drive Finder rather than depend on
# create-dmg.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$ACTUAL_VOLUME"
        open
        tell container window
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set pathbar visible to false
            set sidebar width to 0
            set bounds to {160, 140, 800, 550}
        end tell
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 104
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "MDockPreview.app" to {160, 205}
        set position of item "Applications" to {480, 205}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

sync
for _ in 1 2 3 4 5 6; do
    [ -f "$MOUNT_DIR/.DS_Store" ] && break
    sleep 1
done
sleep 2
[ -f "$MOUNT_DIR/.DS_Store" ] \
    || echo "warning: .DS_Store not written; the DMG may open without its layout" >&2

# The volume icon goes in only after Finder is done, or Finder deletes it while
# the window is open and the shipped image keeps the generic disk icon.
cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT_DIR/.VolumeIcon.icns"
if [ -n "$SETFILE" ]; then
    "$SETFILE" -a V "$MOUNT_DIR/.VolumeIcon.icns"
    "$SETFILE" -a C "$MOUNT_DIR"
fi

chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
sync

hdiutil detach "$MOUNT_DEVICE" >/dev/null 2>&1 \
    || hdiutil detach "$MOUNT_DIR" -force >/dev/null
MOUNTED=false

echo "==> Compressing…"
rm -f "$DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

echo "==> Signing the disk image…"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
hdiutil verify "$DMG" >/dev/null

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo ""
    echo "⚠️  SKIP_NOTARIZE=1 — layout preview only, not distributable:"
    echo "   $DMG ($(du -sh "$DMG" | cut -f1))"
    exit 0
fi

echo "==> Notarizing the DMG (takes a few minutes)…"
xcrun notarytool submit "$DMG" "${NOTARY_CREDS[@]}" --wait

echo "==> Stapling + validating…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo ""
echo "✅ Done: $DMG ($(du -sh "$DMG" | cut -f1))"
