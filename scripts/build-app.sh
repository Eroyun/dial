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
ROOT=$(pwd -P)
[ "$(git rev-parse --show-toplevel)" = "$ROOT" ]
[ -f Package.swift ] && [ -f Tools/DialAwakeHelper.c ]
# SwiftBuild is the official default; native is useful for local SDK-cache stalls.
SWIFT_BUILD_SYSTEM=${SWIFT_BUILD_SYSTEM:-swiftbuild}
case "$SWIFT_BUILD_SYSTEM" in swiftbuild|native) ;; *) echo "Unsupported build system: $SWIFT_BUILD_SYSTEM" >&2; exit 1 ;; esac

# Only these rebuildable outputs may be removed; never follow a symlinked parent.
cleanup_output() {
  python3 - "$ROOT" "$@" <<'PYTHON'
import pathlib
import shutil
import subprocess
import sys
root = pathlib.Path(sys.argv[1]).resolve(strict=True)
assert pathlib.Path(subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], cwd=root, text=True).strip()).resolve() == root
assert (root / "Package.swift").is_file() and (root / "Tools/DialAwakeHelper.c").is_file()
allowed = {".build/app/Dial.app", ".build/dmg", "build/Dial.dmg"}
for relative in sys.argv[2:]:
    assert relative in allowed, relative
    target = root / relative
    assert not any(p.is_symlink() for p in (target, *target.parents) if p != root), target
    if target.is_dir():
        shutil.rmtree(target)
    elif target.exists():
        target.unlink()
PYTHON
}
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

swift build --build-system "$SWIFT_BUILD_SYSTEM" -c release --arch arm64
APP=.build/app/Dial.app
cleanup_output "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$(swift build --build-system "$SWIFT_BUILD_SYSTEM" -c release --arch arm64 --show-bin-path)/Dial" "$APP/Contents/MacOS/Dial"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/KeyboardAutomation.md "$APP/Contents/Resources/KeyboardAutomation.md"
cp -R Resources/ThirdParty "$APP/Contents/Resources/ThirdParty"
clang -std=c11 -Wall -Wextra -Werror -O2 -arch arm64 \
  -framework IOKit -framework CoreFoundation Tools/DialAwakeHelper.c \
  -o "$APP/Contents/Helpers/DialAwakeHelper"
if [ -z "${SIGN_IDENTITY:-}" ] && security find-identity -p codesigning | grep -q '"Dial Developer"'; then
  SIGN_IDENTITY="Dial Developer"
fi
if [ "${1:-}" = --dmg ] && { [ -z "${SIGN_IDENTITY:-}" ] || [ "$SIGN_IDENTITY" = - ]; }; then
  echo "Public releases require a stable signing identity for persistent helper authorization." >&2
  exit 1
fi
swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macosx14.0 \
  Tools/DialAwakeBroker.swift Sources/Dial/AwakeBrokerProtocol.swift \
  -framework Security -framework SystemConfiguration \
  -o "$APP/Contents/Helpers/DialAwakeBroker"
cp Resources/io.github.eroyun.dial.awake.plist "$APP/Contents/Resources/"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP/Contents/Helpers/DialAwakeBroker"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP/Contents/Helpers/DialAwakeHelper"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
"$LSREGISTER" -u "$APP" 2>/dev/null || true
echo "Built $APP"

case "${1:-}" in
  --dmg)
    # A disk image with Dial and an Applications shortcut, so installing is one drag.
    STAGE=.build/dmg
    cleanup_output "$STAGE" build/Dial.dmg
    mkdir -p "$STAGE" build
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname Dial -srcfolder "$STAGE" -ov -format UDZO build/Dial.dmg >/dev/null
    cleanup_output "$STAGE"
    echo "Packed build/Dial.dmg"
    ;;
  --install)
    pkill -x Dial || true
    while pgrep -x Dial >/dev/null; do sleep 0.2; done
    # Refuse symlinks or another application's bundle before replacing this fixed target.
    python3 - "$ROOT" <<'PYTHON'
import pathlib
import plistlib
import shutil
import sys
root = pathlib.Path(sys.argv[1]).resolve(strict=True)
target = pathlib.Path("/Applications/Dial.app")
assert not target.parent.is_symlink() and not target.is_symlink()
if target.exists():
    with (root / "Resources/Info.plist").open("rb") as source:
        expected = plistlib.load(source)["CFBundleIdentifier"]
    with (target / "Contents/Info.plist").open("rb") as installed:
        assert plistlib.load(installed)["CFBundleIdentifier"] == expected
    shutil.rmtree(target)
PYTHON
    cp -R "$APP" /Applications/
    # Unregistering the build copy above can leave Launch Services without any Dial to open.
    "$LSREGISTER" -f /Applications/Dial.app
    # Launch Services can take a moment to pick up the new copy (open fails with -600 until then).
    for _ in 1 2 3 4 5; do open /Applications/Dial.app 2>/dev/null && break; sleep 1; done
    echo "Installed /Applications/Dial.app"
    ;;
esac
