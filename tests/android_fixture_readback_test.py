import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from scripts.android_fixture_readback import read_fixture


class FixtureReadbackTests(unittest.TestCase):
    remote = "files/compatibility/environment.json"
    data = '{"opaque":-0,"text":"世界 é"}'.encode()

    def response(self, args, data=None):
        if "sha256sum" in args and data is None:
            data = hashlib.sha256(self.data).hexdigest().encode() + b"  " + self.remote.encode() + b"\n"
        return subprocess.CompletedProcess(args, 0, stdout=self.data if data is None else data, stderr=b"")

    def test_unknown_255_recovers_only_with_complete_exact_bytes(self):
        calls, delays = [], []
        def device(*args, **kwargs):
            calls.append(args)
            if len(calls) == 2:
                raise subprocess.CalledProcessError(255, args, output=b"", stderr=b"")
            return self.response(args)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            self.assertEqual(read_fixture(device, self.remote, path, delays.append), self.data)
            self.assertEqual(path.read_bytes(), self.data)
            report = json.loads(path.with_name(path.name + ".readback.json").read_text())
            self.assertEqual([x["passed"] for x in report["attempts"]], [False, True])
            self.assertEqual(delays, [2])

    def test_exit_zero_partial_read_is_retained_then_verified(self):
        count = 0
        def device(*args, **kwargs):
            nonlocal count
            if "cat" in args:
                count += 1
                return self.response(args, self.data[:10] if count == 1 else self.data)
            return self.response(args)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            read_fixture(device, self.remote, path, lambda _: None)
            self.assertEqual(path.with_name(path.name + ".attempt-1.partial").read_bytes(), self.data[:10])
            self.assertEqual(path.read_bytes(), self.data)

    def test_permission_missing_and_malformed_source_do_not_retry(self):
        for failure in [subprocess.CalledProcessError(1, [], output=b"", stderr=b"missing file"),
                        subprocess.CalledProcessError(255, [], output=b"", stderr=b"permission denied")]:
            count = 0
            def device(*args, **kwargs):
                nonlocal count
                count += 1
                raise failure
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(subprocess.CalledProcessError):
                    read_fixture(device, self.remote, Path(directory) / "fixture.json", lambda _: self.fail("Permanent error retried"))
                self.assertEqual(count, 1)
        bad = b'{"incomplete":'
        def malformed(*args, **kwargs):
            payload = hashlib.sha256(bad).hexdigest().encode() + b"  " + self.remote.encode() + b"\n" if "sha256sum" in args else bad
            return self.response(args, payload)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(json.JSONDecodeError):
                read_fixture(malformed, self.remote, Path(directory) / "fixture.json", lambda _: self.fail("Malformed source retried"))

    def test_three_attempt_limit_never_publishes_partial_fixture(self):
        delays = []
        def device(*args, **kwargs):
            return self.response(args, b"truncated" if "cat" in args else None)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            with self.assertRaises(RuntimeError):
                read_fixture(device, self.remote, path, delays.append)
            self.assertFalse(path.exists())
            report = json.loads(path.with_name(path.name + ".readback.json").read_text())
            self.assertFalse(report["passed"])
            self.assertEqual(len(report["attempts"]), 3)
            self.assertEqual(delays, [2, 5])


if __name__ == "__main__":
    unittest.main()
