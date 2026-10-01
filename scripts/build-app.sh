#!/bin/bash
# Builds build/Dial.app (Apple silicon) with an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
APP=build/Dial.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --arch arm64 --show-bin-path)/Dial" "$APP/Contents/MacOS/Dial"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
