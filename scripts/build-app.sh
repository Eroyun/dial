#!/bin/bash
# Builds Dial.app (Apple silicon). It is signed with the "Dial Developer" certificate when the
# keychain has one (SIGN_IDENTITY overrides), otherwise ad hoc. macOS ties the Accessibility
# permission to the signature: with the certificate it survives rebuilds and updates, ad hoc it
# has to be turned on again after every build.
#   ./scripts/build-app.sh            → .build/app/Dial.app
#   ./scripts/build-app.sh --dmg      → also build/Dial.dmg
#   ./scripts/build-app.sh --install  → also replaces /Applications/Dial.app and opens it
# The app is built inside the hidden .build folder so Spotlight, Launchpad and "Open With" never
# show a second Dial next to the installed one.
set -euo pipefail
cd "$(dirname "$0")/.."
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

swift build -c release --arch arm64
APP=.build/app/Dial.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/Dial" "$APP/Contents/MacOS/Dial"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -z "${SIGN_IDENTITY:-}" ] && security find-identity -p codesigning | grep -q '"Dial Developer"'; then
  SIGN_IDENTITY="Dial Developer"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
"$LSREGISTER" -u "$APP" 2>/dev/null || true
echo "Built $APP"

case "${1:-}" in
  --dmg)
    # A disk image with Dial and an Applications shortcut, so installing is one drag.
    STAGE=.build/dmg
    rm -rf "$STAGE" build/Dial.dmg
    mkdir -p "$STAGE" build
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname Dial -srcfolder "$STAGE" -ov -format UDZO build/Dial.dmg >/dev/null
    rm -rf "$STAGE"
    echo "Packed build/Dial.dmg"
    ;;
  --install)
    pkill -x Dial || true
    while pgrep -x Dial >/dev/null; do sleep 0.2; done
    rm -rf /Applications/Dial.app
    cp -R "$APP" /Applications/
    # Unregistering the build copy above can leave Launch Services without any Dial to open.
    "$LSREGISTER" -f /Applications/Dial.app
    open /Applications/Dial.app
    echo "Installed /Applications/Dial.app"
    ;;
esac
