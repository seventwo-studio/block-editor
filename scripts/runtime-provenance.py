"""Record and verify the exact checkout and build inputs for runtime evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess


LABELS = ("swift", "wasm", "android-api26-x86_64", "android-api35-x86_64", "android-api35-arm64-v8a")
INPUTS = ("scripts/ci-inputs.json", "bun.lock", "benchmarks/workloads.json")


def input_paths():
    return (*INPUTS, *(str(path) for path in sorted(Path("tests/BlockEditorCoreTests/Fixtures").glob("*.json"))))


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def source():
    if git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Runtime evidence requires a clean checkout, including untracked source")
    return {"commit": git("rev-parse", "HEAD"), "tree": git("rev-parse", "HEAD^{tree}")}


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def roles(label):
    if label == "swift":
        return {"debug-bridge", "release-bridge", "relay-client"}
    if label == "wasm":
        return {"wasm", "debug-bridge", "relay-client"}
    return {"jni", "swift-bridge", "cxx-runtime", "test-apk"}


def installed_names(label):
    if label == "swift":
        return {"swift-macos"}
    if label == "wasm":
        return {"swift-linux", "swift-wasm"}
    api = label.split("-")[1].removeprefix("api")
    return {"swift-linux", "swift-android", "gradle", "android-platform", "android-ndk",
            "android-build-tools", "android-command-tools", "android-platform-tools", "android-emulator", f"android-image-{api}"}


def validate_inputs(label, installed):
    lock = json.loads(Path("scripts/ci-inputs.json").read_text())["artifacts"]
    if set(installed) != installed_names(label) or any(value != lock[name] for name, value in installed.items()):
        raise ValueError(f"{label}: installed inputs differ from the pinned toolchain lock")


def record(label, installed_path, assets, output):
    installed = json.loads(Path(installed_path).read_text())
    validate_inputs(label, installed)
    binaries = {}
    for asset in assets:
        role, path = asset.split("=", 1)
        if role in binaries:
            raise ValueError(f"Duplicate binary role: {role}")
        size = Path(path).stat().st_size
        if size <= 0:
            raise ValueError(f"Empty binary: {path}")
        binaries[role] = {"path": path, "bytes": size, "sha256": digest(path)}
    if set(binaries) != roles(label):
        raise ValueError(f"{label}: missing or unexpected built binaries")
    report = {"version": 1, "runtime": label, "source": source(),
              "workflowRun": os.environ.get("GITHUB_RUN_ID"), "workflowAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
              "host": {"system": platform.system(), "machine": platform.machine(), "release": platform.release()},
              "inputs": {path: digest(path) for path in input_paths()}, "installed": installed, "binaries": binaries}
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    (output / f"runtime-provenance-{label}.json").write_text(json.dumps(report, indent=2) + "\n")


def verify(root):
    expected_source = source()
    expected_inputs = {path: digest(path) for path in input_paths()}
    for label in LABELS:
        matches = list(Path(root).rglob(f"runtime-provenance-{label}.json"))
        if len(matches) != 1:
            raise ValueError(f"{label}: expected exactly one provenance manifest, found {len(matches)}")
        report = json.loads(matches[0].read_text())
        if report.get("version") != 1 or report.get("runtime") != label:
            raise ValueError(f"{label}: invalid provenance manifest")
        if report.get("source") != expected_source or report.get("inputs") != expected_inputs:
            raise ValueError(f"{label}: stale checkout, tree or fixture/build inputs")
        if os.environ.get("GITHUB_RUN_ID") and report.get("workflowRun") != os.environ["GITHUB_RUN_ID"]:
            raise ValueError(f"{label}: wrong workflow run")
        validate_inputs(label, report["installed"])
        if set(report.get("binaries", {})) != roles(label):
            raise ValueError(f"{label}: missing or unexpected built binaries")
        for binary in report["binaries"].values():
            if (type(binary.get("bytes")) is not int or binary["bytes"] <= 0
                    or not isinstance(binary.get("sha256"), str) or len(binary["sha256"]) != 64
                    or any(char not in "0123456789abcdef" for char in binary["sha256"])):
                raise ValueError(f"{label}: invalid binary size/hash")
        print(f"{label}: exact checkout/tree, locked inputs and binary hashes recorded")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    recording = commands.add_parser("record")
    recording.add_argument("label", choices=LABELS)
    recording.add_argument("installed_inputs")
    recording.add_argument("output")
    recording.add_argument("assets", nargs="+")
    verification = commands.add_parser("verify")
    verification.add_argument("root")
    args = parser.parse_args()
    if args.command == "record":
        record(args.label, args.installed_inputs, args.assets, args.output)
    else:
        verify(args.root)


if __name__ == "__main__":
    main()
