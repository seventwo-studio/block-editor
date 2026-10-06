"""Fault-inject a disconnected runtime into the actual installed-IME driver."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("writing_ime", ROOT / "scripts/test-android-writing-builtin-ime.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class WritingImeFailureEvidenceTest(unittest.TestCase):
    def test_original_instrumentation_failure_survives_failed_settings_and_collection(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "test.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("fixture", b"test host")
            output = Path(directory) / "evidence"
            primary = None

            def run(command, **kwargs):
                nonlocal primary
                if command[0] == "git":
                    value = b"a" * 40 if "rev-parse" in command else b""
                elif "instrument" in command:
                    primary = subprocess.CalledProcessError(255, command, output=b"IME case started; runtime disconnected\n")
                    raise primary
                elif primary is not None:
                    raise subprocess.CalledProcessError(1, command, output=b"error: device unavailable\n")
                elif "settings" in command:
                    value = b"com.android.inputmethod.latin/.LatinIME" if command[-1] == "default_input_method" else b"null"
                elif "getprop" in command:
                    value = {"ro.build.version.sdk": b"26", "ro.product.cpu.abi": b"x86_64"}.get(command[-1], b"fixture")
                elif "pm" in command:
                    value = b"package:/data/app/fixture/base.apk"
                elif "exec-out" in command:
                    value = apk.read_bytes()
                else:
                    value = b""
                return subprocess.CompletedProcess(command, 0, stdout=value)

            arguments = ["runner", "--sdk", directory, "--serial", "fixture-runtime", "--apk", str(apk), "--output", str(output)]
            with patch("sys.argv", arguments), patch.object(runner.subprocess, "run", side_effect=run):
                with self.assertRaises(subprocess.CalledProcessError) as failure:
                    runner.main()
            self.assertIs(failure.exception, primary)
            report = json.loads((output / "environment.json").read_text())
            self.assertFalse(report["passed"])
            self.assertEqual(report["executedTests"], 0)
            self.assertIn("255", report["failure"])
            self.assertIsNone(report["settingsAfter"])
            self.assertIn("CalledProcessError", report["settingsVerificationFailure"])
            self.assertGreater(len(report["diagnosticCollectionFailures"]), 0)
            self.assertEqual((output / "enter-instrumentation.log").read_bytes(), primary.stdout)
            self.assertEqual((output / "settings-after.log").read_bytes(), b"error: device unavailable\n")

    def test_completed_cases_cannot_pass_without_verified_final_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "test.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("fixture", b"test host")
            output = Path(directory) / "evidence"
            executed = 0
            run_id = None

            def run(command, **kwargs):
                nonlocal executed, run_id
                if command[0] == "git":
                    value = b"a" * 40 if "rev-parse" in command else b""
                elif "instrument" in command:
                    run_id = command[command.index("nativeInputRun") + 1]
                    executed += 1
                    value = b"OK (1 test)\n"
                elif "settings" in command:
                    if executed == 2:
                        raise subprocess.TimeoutExpired(command, 120, output=b"settings read timed out\n")
                    value = b"com.android.inputmethod.latin/.LatinIME" if command[-1] == "default_input_method" else b"null"
                elif "getprop" in command:
                    value = {"ro.build.version.sdk": b"26", "ro.product.cpu.abi": b"x86_64"}.get(command[-1], b"fixture")
                elif "pm" in command:
                    value = b"package:/data/app/fixture/base.apk"
                elif "exec-out" in command:
                    name = command[-1]
                    if name.endswith("base.apk"):
                        value = apk.read_bytes()
                    elif name.endswith("-proof.json"):
                        mode = "soft-break" if "soft-break" in name else "enter"
                        value = json.dumps({
                            "runID": run_id, "mode": mode, "protocol": 4, "passed": True,
                            "heldAccepted": {}, "initialAccepted": {}, "heldReceipt": {"received": []},
                            "heldDeferred": [{}], "composingDraft": {"reason": "Native composition is pending",
                            "selectionStart": 3, "selectionEnd": 3}, "committedReceipt": {"received": [1, 2, 3]},
                            "remoteOnlyUndoSnapshot": {"blocks": []}, "remoteOnlySnapshot": {"blocks": []},
                            "failures": [], "retainedDrafts": [], "pendingDrafts": [],
                            "lastDeferred": [], "lastRecovery": None,
                        }).encode()
                    elif name.endswith(".png"):
                        value = b"\x89PNG\r\n\x1a\nfixture"
                    else:
                        value = b"{}"
                else:
                    value = b""
                return subprocess.CompletedProcess(command, 0, stdout=value)

            arguments = ["runner", "--sdk", directory, "--serial", "fixture-runtime", "--apk", str(apk), "--output", str(output)]
            with patch("sys.argv", arguments), patch.object(runner.subprocess, "run", side_effect=run):
                with self.assertRaisesRegex(RuntimeError, "System input settings could not be verified") as failure:
                    runner.main()
            self.assertIsInstance(failure.exception.__cause__, subprocess.TimeoutExpired)
            report = json.loads((output / "environment.json").read_text())
            self.assertEqual(report["executedTests"], 2)
            self.assertFalse(report["passed"])
            self.assertNotIn("failure", report)
            self.assertIsNone(report["settingsAfter"])
            self.assertIn("TimeoutExpired", report["settingsVerificationFailure"])
            self.assertEqual((output / "settings-after.log").read_bytes(), b"settings read timed out\n")


if __name__ == "__main__":
    unittest.main()
