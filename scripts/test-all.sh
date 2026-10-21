#!/bin/bash
# Hardware-free gates: compile production once, run every standalone test.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ]
[ "$(uname -s)" = Darwin ] || { echo "Dial tests require macOS" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "Run Dial tests without root privileges" >&2; exit 1; }

exec python3 - <<'PYTHON'
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import tempfile
import time

root = Path.cwd()
swift_tests = sorted((root / "Tests").rglob("*.swift"))
python_tests = sorted((root / "Tests").rglob("*.py"))
if not swift_tests or not python_tests:
    sys.exit("Expected both Swift and Python tests")
sources = sorted(p for p in (root / "Sources/Dial").glob("*.swift") if p.name != "DialApp.swift")
failures = []
passed = {"Swift": 0, "Python": 0}
started = time.monotonic()


def run(command, **kwargs):
    print("+ " + shlex.join(map(str, command)), flush=True)
    return subprocess.run(command, **kwargs).returncode == 0


with tempfile.TemporaryDirectory(prefix="dial-tests-", dir="/tmp") as directory:
    temporary = Path(directory)
    # Keep compiler caches, generated modules, binaries and runtime scratch local.
    environment = os.environ.copy()
    environment["TMPDIR"] = str(temporary) + "/"
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["DIAL_TEST_ROOT"] = str(root)
    cache = temporary / "module-cache"
    c_module = temporary / "CDDC"
    c_module.mkdir()
    header = root / "Sources/CDDC/include/CDDC.h"
    (c_module / "module.modulemap").write_text(
        "module CDDC { header " + json.dumps(str(header)) + " export * }\n")
    target = platform.machine() + "-apple-macosx14.0"
    swift_flags = ["-swift-version", "5", "-Onone", "-target", target,
                   "-module-cache-path", str(cache), "-I", str(c_module)]

    # Uses the helper suite's existing DIAL_AWAKE_TESTING build and isolated cwd
    # fixtures. The production helper is compiled by that suite, never launched.
    for test in python_tests:
        if run([sys.executable, str(test), "-v"], cwd=root, env=environment):
            passed["Python"] += 1
        else:
            failures.append(str(test.relative_to(root)))

    shim = temporary / "shim.o"
    if not run(["clang", "-target", target, "-c", str(root / "Sources/CDDC/shim.c"),
                "-I", str(header.parent), "-o", str(shim)], env=environment):
        sys.exit("FAIL: CDDC support compilation; Swift tests NOT RUN")
    # DialApp.swift owns @main and the live Probe commands; neither is linked.
    # No SwiftPM build/cache or running application is involved.
    if not run(["swiftc", *swift_flags, "-whole-module-optimization", "-parse-as-library", "-enable-testing",
                "-emit-library", "-emit-module", "-module-name", "DialTestSupport",
                "-emit-module-path", str(temporary / "DialTestSupport.swiftmodule"),
                *map(str, sources), str(shim), "-framework", "IOKit",
                "-framework", "CoreFoundation", "-o", str(temporary / "libDialTestSupport.dylib")],
               env=environment):
        sys.exit("FAIL: production support compilation; Swift tests NOT RUN")

    for index, test in enumerate(swift_tests):
        copied = temporary / (str(index) + "-" + test.name)
        # Preserve test bodies/assertions and report original source coordinates.
        copied.write_text("@testable import DialTestSupport\n#sourceLocation(file: "
                          + json.dumps(str(test)) + ", line: 1)\n" + test.read_text())
        binary = temporary / ("test-" + str(index))
        command = ["swiftc", *swift_flags, "-parse-as-library", "-I", str(temporary),
                   "-L", str(temporary), "-lDialTestSupport", "-Xlinker", "-rpath",
                   "-Xlinker", str(temporary), str(copied), "-o", str(binary)]
        if run(command, env=environment) and run([str(binary)], cwd=temporary, env=environment):
            passed["Swift"] += 1
            print("PASS " + str(test.relative_to(root)), flush=True)
        else:
            failures.append(str(test.relative_to(root)))
            print("FAIL " + str(test.relative_to(root)), flush=True)

print(f"Results: {passed['Swift']}/{len(swift_tests)} Swift programs; "
      f"{passed['Python']}/{len(python_tests)} Python suites passed "
      f"({time.monotonic() - started:.1f}s)", flush=True)
if failures:
    sys.exit("Failed tests:\n" + "\n".join(failures))
PYTHON
