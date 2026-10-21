#!/usr/bin/env python3
"""Hardware-free subprocess tests; production is compiled, never activated.

Run: python3 Tests/DialAwakeHelperTests.py -v
The test build uses fixed fixture filenames inside temporary cwd directories;
state is persisted/kernel (0/1, persisted -1 = absent, -2 = malformed).
Timers are shortened at compile time (start/child .5s, heartbeat 1s, monitor .2s).
No root access, installed service, pmset execution or power-setting reads occur.
"""
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Session:
    def __init__(self, test, state="0 0\n", behavior="ok\n", lock=None):
        self.directory = tempfile.TemporaryDirectory(prefix="dial-awake-", dir="/tmp")
        test.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        for name, contents in (("state", state), ("behavior", behavior), ("owner", "alive\n")):
            (self.path / name).write_text(contents)
        if lock:
            lock(self.path)
        self.owner = subprocess.Popen(["/bin/sleep", "60"])
        test.addCleanup(self.close)
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(self.path / "gui.sock"))
        self.server.listen(4)
        self.server.settimeout(3)
        self.process = self.launch(test.binary)
        self.connection, _ = self.server.accept()
        self.connection.setblocking(False)
        self.buffer = b""

    def launch(self, binary):
        return subprocess.Popen(
            [str(binary), "--session", str(self.path / "gui.sock"),
             str(self.owner.pid), str(os.getuid())], cwd=self.path,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def close(self):
        if hasattr(self, "connection"):
            self.connection.close()
        if hasattr(self, "process"):
            try:
                self.process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.communicate()
        if hasattr(self, "server"):
            self.server.close()
        if self.owner.poll() is None:
            self.owner.terminate()
        self.owner.wait()

    def set(self, name, value):
        pending = self.path / (name + ".next")
        pending.write_text(value)
        pending.replace(self.path / name)

    def send(self, data):
        self.connection.sendall(data)

    def line(self, timeout=3):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.connection], [], [], remaining)[0]:
                raise AssertionError("helper protocol line timed out")
            data = self.connection.recv(4096)
            if not data:
                raise AssertionError("helper disconnected before expected protocol line")
            self.buffer += data
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line.decode("ascii")

    def start(self, test):
        test.assertEqual(self.line(), "ready")
        self.send(b"start\n")
        test.assertEqual(self.line(), "active")

    def finish(self, test, code=0):
        stdout, stderr = self.process.communicate(timeout=3)
        test.assertEqual(self.process.returncode, code, (stdout, stderr))
        test.assertEqual(stdout + stderr, b"")

    def writes(self):
        p = self.path / "writes"
        return [tuple(map(int, line.split())) for line in p.read_text().splitlines()] if p.exists() else []

    def wait_writes(self, count):
        deadline = time.monotonic() + 2
        while len(self.writes()) < count:
            if time.monotonic() > deadline:
                raise AssertionError("fixture write was not observed")
            time.sleep(.01)


@unittest.skipUnless(sys.platform == "darwin", "macOS helper uses IOKit/libproc/kqueue")
class HelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="dial-awake-build-", dir="/tmp")
        cls.addClassCleanup(cls.build.cleanup)
        cls.binary = Path(cls.build.name) / "helper-test"
        cls.production = Path(cls.build.name) / "helper-production"
        common = ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                  str(ROOT / "Tools/DialAwakeHelper.c"), "-framework", "IOKit",
                  "-framework", "CoreFoundation"]
        subprocess.run(common + ["-o", str(cls.production)], check=True, capture_output=True)
        subprocess.run(common + ["-DDIAL_AWAKE_TESTING", "-o", str(cls.binary)],
                       check=True, capture_output=True)

    def test_stop_restores_and_keeps_lock_inode(self):
        s = Session(self)
        s.start(self)
        inode = (s.path / "lock").stat().st_ino
        s.send(b"stop\n")
        self.assertEqual(s.line(), "stopped")
        s.finish(self)
        self.assertEqual((s.path / "state").read_text(), "0 0\n")
        self.assertEqual([v for v, _ in s.writes()], [1, 0])
        self.assertEqual((s.path / "lock").stat().st_ino, inode)

    def test_eof_restores(self):
        s = Session(self); s.start(self)
        s.connection.close()
        s.finish(self)
        self.assertEqual([v for v, _ in s.writes()], [1, 0])

    def test_heartbeat_timeout_restores(self):
        s = Session(self); s.start(self)
        self.assertEqual(s.line(), "stopped")
        s.finish(self)
        self.assertEqual((s.path / "state").read_text(), "0 0\n")

    def test_pings_keep_alive_and_receive_verified_pong(self):
        s = Session(self); s.start(self)
        for _ in range(7):
            s.send(b"ping\n")
            self.assertEqual(s.line(), "pong")
            time.sleep(.18)
        self.assertIsNone(s.process.poll())
        s.send(b"ping\nping\nping\n")
        self.assertEqual([s.line() for _ in range(3)], ["pong"] * 3)
        s.send(b"stop\n"); self.assertEqual(s.line(), "stopped"); s.finish(self)

    def test_real_owner_exit_restores(self):
        s = Session(self); s.start(self)
        s.owner.terminate(); s.owner.wait()
        self.assertEqual(s.line(), "stopped"); s.finish(self)

    def test_owner_probe_unknown_restores(self):
        s = Session(self); s.start(self)
        s.set("owner", "unknown\n")
        self.assertEqual(s.line(), "stopped"); s.finish(self)

    def test_signals_restore(self):
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT):
            with self.subTest(signal=sig):
                s = Session(self); s.start(self)
                s.process.send_signal(sig)
                self.assertEqual(s.line(), "stopped"); s.finish(self)

    def test_missing_start_never_writes(self):
        s = Session(self)
        self.assertEqual(s.line(), "ready")
        self.assertEqual(s.line(), "error baseline"); s.finish(self, 1)
        self.assertEqual(s.writes(), [])

    def test_partial_start_does_not_extend_handshake(self):
        s = Session(self); self.assertEqual(s.line(), "ready")
        s.send(b"star")
        self.assertEqual(s.line(), "error baseline"); s.finish(self, 1)
        self.assertEqual(s.writes(), [])

    def test_non_start_handshake_refused(self):
        for message in (b"ping\n", b"stop\n", b"start\x00\n", b"\xff\n"):
            with self.subTest(message=message):
                s = Session(self); self.assertEqual(s.line(), "ready")
                s.send(message)
                self.assertEqual(s.line(), "error baseline"); s.finish(self, 1)
                self.assertEqual(s.writes(), [])

    def test_refuses_true_unknown_malformed_and_mismatched_baselines(self):
        for state in ("1 1\n", "-2 0\n", "0 -2\n", "1 0\n", "0 1\n", "nonsense\n",
                      "0 0 trailing\n", "-1 1\n", "2 2\n"):
            with self.subTest(state=state):
                s = Session(self, state=state)
                self.assertEqual(s.line(), "error baseline"); s.finish(self, 1)
                self.assertEqual(s.writes(), [])
                self.assertEqual((s.path / "state").read_text(), state)

    def test_absent_key_is_false_and_restore_leaves_explicit_false(self):
        s = Session(self, state="-1 0\n"); s.start(self)
        s.send(b"stop\n"); self.assertEqual(s.line(), "stopped"); s.finish(self)
        self.assertEqual((s.path / "state").read_text(), "0 0\n")

    def test_baseline_changed_during_handshake_preserves_external_setting(self):
        s = Session(self); self.assertEqual(s.line(), "ready")
        s.set("state", "1 1\n"); s.send(b"start\n")
        self.assertEqual(s.line(), "error baseline"); s.finish(self, 1)
        self.assertEqual(s.writes(), [])

    def test_enable_partial_failure_is_restored(self):
        s = Session(self, behavior="fail-enable\n")
        self.assertEqual(s.line(), "ready"); s.send(b"start\n")
        self.assertEqual(s.line(), "error enable")
        self.assertEqual(s.line(), "stopped"); s.finish(self, 1)
        self.assertEqual([v for v, _ in s.writes()], [1, 0])

    def test_successful_command_without_enable_readback_is_failure(self):
        s = Session(self, behavior="noop-enable\n")
        self.assertEqual(s.line(), "ready"); s.send(b"start\n")
        self.assertEqual(s.line(), "error enable")
        self.assertEqual(s.line(), "stopped"); s.finish(self, 1)

    def test_restore_failure_does_not_claim_stopped(self):
        for behavior in ("fail-restore\n", "noop-restore\n", "hang-restore\n"):
            with self.subTest(behavior=behavior):
                s = Session(self, behavior=behavior); s.start(self)
                s.send(b"stop\n")
                self.assertEqual(s.line(), "error restore"); s.finish(self, 1)
                self.assertNotIn(b"stopped", s.buffer)
                self.assertEqual((s.path / "state").read_text(), "1 1\n")
                for _, pid in s.writes():
                    with self.assertRaises(ProcessLookupError): os.kill(pid, 0)

    def test_power_reset_reapplies_before_pong(self):
        for state in ("0 0\n", "1 0\n"):
            with self.subTest(reset=state):
                s = Session(self); s.start(self)
                s.set("state", state); s.send(b"ping\n")
                self.assertEqual(s.line(), "pong")
                self.assertEqual((s.path / "state").read_text(), "1 1\n")
                self.assertEqual([v for v, _ in s.writes()], [1, 1])
                s.send(b"stop\n"); self.assertEqual(s.line(), "stopped"); s.finish(self)

    def test_periodic_readback_reapplies_without_ping(self):
        s = Session(self); s.start(self)
        s.set("state", "1 0\n"); s.wait_writes(2)
        s.send(b"stop\n"); self.assertEqual(s.line(), "stopped"); s.finish(self)
        self.assertEqual([v for v, _ in s.writes()], [1, 1, 0])

    def test_active_unknown_stops_without_pong_and_restores(self):
        s = Session(self); s.start(self)
        s.set("state", "-2 0\n"); s.send(b"ping\n")
        self.assertEqual(s.line(), "error enable")
        self.assertEqual(s.line(), "stopped"); s.finish(self, 1)
        self.assertEqual((s.path / "state").read_text(), "0 0\n")

    def test_reapply_failure_restores(self):
        s = Session(self); s.start(self)
        s.set("behavior", "fail-enable\n"); s.set("state", "1 0\n")
        s.send(b"ping\n")
        self.assertEqual(s.line(), "error enable")
        self.assertEqual(s.line(), "stopped"); s.finish(self, 1)
        self.assertEqual([v for v, _ in s.writes()], [1, 1, 0])

    def test_hung_enable_is_killed_and_reaped_before_restore(self):
        s = Session(self, behavior="hang-enable\n")
        self.assertEqual(s.line(), "ready"); s.send(b"start\n")
        self.assertEqual(s.line(), "error enable")
        self.assertEqual(s.line(), "stopped"); s.finish(self, 1)
        self.assertEqual([v for v, _ in s.writes()], [1, 0])
        for _, pid in s.writes():
            with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
        self.assertEqual((s.path / "state").read_text(), "0 0\n")

    def test_stop_during_hung_enable_cancels_then_restores(self):
        s = Session(self, behavior="hang-enable\n")
        self.assertEqual(s.line(), "ready"); s.send(b"start\n"); s.wait_writes(1)
        s.send(b"stop\n")
        self.assertEqual(s.line(), "stopped"); s.finish(self)
        for _, pid in s.writes():
            with self.assertRaises(ProcessLookupError): os.kill(pid, 0)

    def test_invalid_active_protocol_restores(self):
        for message in (b"start\n", b"bogus\n", b"x" * 32):
            with self.subTest(message=message):
                s = Session(self); s.start(self); s.send(message)
                self.assertEqual(s.line(), "stopped"); s.finish(self)

    def test_unsafe_lock_refused(self):
        def symlink(path):
            (path / "target").write_text("preserve")
            (path / "lock").symlink_to(path / "target")
        def unsafe_mode(path):
            (path / "lock").touch(mode=0o666)
            (path / "lock").chmod(0o666)
        def hardlink(path):
            (path / "target").touch(mode=0o600)
            os.link(path / "target", path / "lock")
        for lock in (symlink, unsafe_mode, hardlink, lambda p: (p / "lock").mkdir()):
            with self.subTest(lock=lock):
                s = Session(self, lock=lock)
                self.assertEqual(s.line(), "error baseline"); s.finish(self, 1)
                self.assertEqual(s.writes(), [])
                if (s.path / "target").is_file() and lock is symlink:
                    self.assertEqual((s.path / "target").read_text(), "preserve")

    def test_second_helper_refused_while_lock_held(self):
        s = Session(self); s.start(self)
        second = s.launch(self.binary)
        try:
            connection, _ = s.server.accept()
            with connection:
                connection.settimeout(2)
                self.assertEqual(connection.recv(100), b"error baseline\n")
            second.communicate(timeout=2)
            self.assertEqual(second.returncode, 1)
            self.assertEqual([v for v, _ in s.writes()], [1])
        finally:
            if second.poll() is None: second.kill()
            second.communicate()
        s.send(b"stop\n"); self.assertEqual(s.line(), "stopped"); s.finish(self)

    def test_check_is_read_only_and_classifies_baseline(self):
        with tempfile.TemporaryDirectory(prefix="dial-awake-check-", dir="/tmp") as directory:
            p = Path(directory)
            for state, output, code in (("0 0\n", "false\n", 0), ("-1 0\n", "false\n", 0),
                                        ("1 1\n", "true\n", 2), ("1 0\n", "unknown\n", 1),
                                        ("-2 0\n", "unknown\n", 1)):
                with self.subTest(state=state):
                    (p / "state").write_text(state)
                    result = subprocess.run([self.binary, "--check"], cwd=p, capture_output=True,
                                            text=True, timeout=2)
                    self.assertEqual((result.returncode, result.stdout, result.stderr),
                                     (code, output, ""))
                    self.assertEqual(sorted(x.name for x in p.iterdir()), ["state"])
                    self.assertEqual((p / "state").read_text(), state)

    def test_bad_arguments_and_owner_identity_refused_without_writes(self):
        with tempfile.TemporaryDirectory(prefix="dial-awake-args-", dir="/tmp") as directory:
            for args in ([], ["--session", "/tmp/no-socket", "0", str(os.getuid())],
                         ["--session", "/tmp/no-socket", str(os.getpid()), "-1"],
                         ["--session", "/tmp/no-socket", "99999999999999999999", "0"],
                         ["--session", "/tmp/no-socket", str(os.getpid()), str(os.getuid() + 1)]):
                with self.subTest(args=args):
                    result = subprocess.run([self.binary] + args, cwd=directory,
                                            capture_output=True, timeout=2)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
