#!/bin/bash
# Hardware-free tests only: no privileged helper launch or power-setting writes.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
[ "$(git rev-parse --show-toplevel)" = "$ROOT" ]
[ "$(uname -s)" = Darwin ] || { echo "Keep-awake tests require macOS" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "Run keep-awake tests without root privileges" >&2; exit 1; }

TEST_DIR=$(mktemp -d /tmp/dial-awake-script.XXXXXXXX)
cleanup() {
  python3 - "$TEST_DIR" <<'PYTHON'
import pathlib
import shutil
import sys
path = pathlib.Path(sys.argv[1])
assert path.parent == pathlib.Path("/tmp") and path.name.startswith("dial-awake-script.")
assert not path.is_symlink()
shutil.rmtree(path)
PYTHON
}
trap cleanup EXIT

python3 Tests/DialAwakeHelperTests.py -v
swiftc -warnings-as-errors Sources/Dial/AwakeSession.swift Tests/AwakeSessionTests.swift \
  -o "$TEST_DIR/awake-session-tests"
"$TEST_DIR/awake-session-tests"
