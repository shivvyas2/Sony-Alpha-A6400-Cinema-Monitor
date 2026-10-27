#!/bin/bash
# Builds CinemaHUD.app (release) and packages it into build/CinemaHUD-<version>.dmg.
# The version and build number come from Resources/Info.plist, so the file name and the
# volume name Finder shows always say which build this is.
#
# Signing, from the environment (CI sets these from repository secrets):
#   SIGN_IDENTITY   "Developer ID Application: …" — hardened runtime + timestamp; unset signs ad-hoc
#   NOTARY_PROFILE  notarytool keychain profile, or
#   NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER  App Store Connect API key (.p8 path, key id, issuer)
# With an identity and notary credentials the DMG is notarized and stapled.
set -euo pipefail
cd "$(dirname "$0")/.."
APP_NAME=CinemaHUD
BUILD=build
PLIST=Resources/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
APP="$BUILD/$APP_NAME.app"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"
VOLNAME="$APP_NAME $VERSION"

echo "▸ version $VERSION (build $BUILD_NUMBER)"

echo "▸ swift build (release)"
swift build -c release --product "$APP_NAME" 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" || true
BIN="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"
test -x "$BIN"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
if [ -f design/icon/AppIcon.icns ]; then cp design/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; else python3 scripts/make-icon.py "$APP/Contents/Resources/AppIcon.icns"; fi

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "▸ codesign ($SIGN_IDENTITY)"
    codesign --force --options runtime --timestamp --entitlements Resources/CinemaHUD.entitlements --sign "$SIGN_IDENTITY" "$APP"
else
    echo "▸ codesign (ad-hoc)"
    codesign --force --deep --sign - --timestamp=none "$APP"
fi
codesign --verify --verbose=2 "$APP" 2>&1 | tail -1

echo "▸ dmg"
STAGE="$BUILD/dmg-stage"
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        NOTARY=(--keychain-profile "$NOTARY_PROFILE")
    elif [ -n "${NOTARY_KEY:-}" ]; then
        NOTARY=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    fi
    if [ -n "${NOTARY+x}" ]; then
        echo "▸ notarize"
        xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
        xcrun stapler staple "$DMG"
        xcrun stapler staple "$APP"
    fi
fi
# Older builds wrote an unversioned CinemaHUD.dmg; remove it so the newest file is unambiguous.
rm -f "$BUILD/$APP_NAME.dmg"
echo "✔ $DMG ($(du -h "$DMG" | cut -f1)) — mounts as \"$VOLNAME\""
