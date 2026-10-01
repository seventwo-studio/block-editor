"""Reject stale or incomplete runtime provenance without compiling a runtime."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("provenance", ROOT / "scripts/runtime-provenance.py")
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)


class RuntimeProvenanceTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        previous = Path.cwd()
        input_paths = provenance.input_paths()
        os.chdir(self.directory.name)
        self.addCleanup(os.chdir, previous)
        for name in input_paths:
            path = Path(name)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT / name).read_bytes())
        self.source = {"commit": "a" * 40, "tree": "b" * 40}
        self.source_patch = patch.object(provenance, "source", return_value=self.source)
        self.source_patch.start()
        self.addCleanup(self.source_patch.stop)
        self.environment = patch.dict(os.environ, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2"})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        lock = json.loads(Path("scripts/ci-inputs.json").read_text())["artifacts"]
        for label in provenance.LABELS:
            installed = Path(f"{label}-installed.json")
            installed.write_text(json.dumps({name: lock[name] for name in provenance.installed_names(label)}))
            binary = Path(f"{label}.binary")
            binary.write_bytes(b"test-binary")
            provenance.record(label, installed, [f"{role}={binary}" for role in provenance.roles(label)], "reports")

    def rewrite(self, change):
        path = Path("reports/runtime-provenance-wasm.json")
        value = json.loads(path.read_text())
        change(value)
        path.write_text(json.dumps(value))

    def test_complete_five_bundles_and_earlier_attempts_are_valid(self):
        # Successful jobs from an earlier attempt of the same run remain usable.
        self.rewrite(lambda value: value.update(workflowAttempt="1"))
        provenance.verify("reports")

    def test_stale_source_tree_run_and_locked_inputs_fail(self):
        original = Path("reports/runtime-provenance-wasm.json").read_bytes()
        for change in (
            lambda value: value["source"].update(tree="c" * 40),
            lambda value: value.update(workflowRun="124"),
            lambda value: value["installed"]["swift-linux"].update(sha256="c" * 64),
        ):
            Path("reports/runtime-provenance-wasm.json").write_bytes(original)
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.rewrite(change)
                provenance.verify("reports")

    def test_current_fixture_bytes_must_match_recorded_inputs(self):
        Path("tests/BlockEditorCoreTests/Fixtures/recovery.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "stale"):
            provenance.verify("reports")

    def test_new_fixture_requires_fresh_manifests(self):
        Path("tests/BlockEditorCoreTests/Fixtures/provenance-extra.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "stale"):
            provenance.verify("reports")

    def test_missing_duplicate_and_partial_evidence_fail(self):
        original = Path("reports/runtime-provenance-wasm.json")
        duplicate = Path("reports/duplicate/runtime-provenance-wasm.json")
        duplicate.parent.mkdir()
        duplicate.write_bytes(original.read_bytes())
        with self.assertRaisesRegex(ValueError, "found 2"):
            provenance.verify("reports")
        duplicate.unlink()
        self.rewrite(lambda value: value["binaries"].pop("wasm"))
        with self.assertRaisesRegex(ValueError, "binaries"):
            provenance.verify("reports")
        original.unlink()
        with self.assertRaisesRegex(ValueError, "found 0"):
            provenance.verify("reports")

    def test_empty_executables_fail_recording(self):
        Path("wasm.binary").write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "Empty binary"):
            provenance.record("wasm", "wasm-installed.json", ["wasm=wasm.binary"], "reports")

    def test_tracked_and_untracked_source_edits_fail_capture(self):
        self.source_patch.stop()
        for status in (" M Sources/BlockEditorCore/EditorSession.swift", "?? Sources/BlockEditorCore/Extra.swift"):
            with patch.object(provenance, "git", return_value=status):
                with self.assertRaisesRegex(ValueError, "clean checkout"):
                    provenance.source()


if __name__ == "__main__":
    unittest.main()
