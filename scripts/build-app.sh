#!/bin/bash
# Builds build/Dial.app (Apple silicon) with an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
APP=build/Dial.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/Dial" "$APP/Contents/MacOS/Dial"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

# --dmg: a disk image with Dial and an Applications shortcut, so installing is one drag.
if [[ "${1:-}" == "--dmg" ]]; then
  STAGE=build/dmg
  rm -rf "$STAGE" build/Dial.dmg
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname Dial -srcfolder "$STAGE" -ov -format UDZO build/Dial.dmg >/dev/null
  echo "Packed build/Dial.dmg"
fi
