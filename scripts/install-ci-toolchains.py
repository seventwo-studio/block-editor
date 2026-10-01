#!/usr/bin/env python3
"""Install only locked official artifacts into a fresh, disposable CI directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import urllib.request


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["apple", "wasm", "android"])
    parser.add_argument("root", type=Path)
    parser.add_argument("--api", choices=["26", "35"], default="35")
    args = parser.parse_args()
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    if any(root.iterdir()):
        raise RuntimeError(f"Refusing to overwrite nonempty toolchain directory: {root}")
    lock = json.loads(Path(__file__).with_name("ci-inputs.json").read_text())
    if lock["version"] != 1:
        raise RuntimeError("Unsupported toolchain lock")
    artifacts = lock["artifacts"]
    installed = {}

    def archive(name):
        entry = artifacts[name]
        target = root / (name + (".pkg" if entry["url"].endswith(".pkg") else ".zip" if entry["url"].endswith(".zip") else ".tar.gz"))
        digest = hashlib.sha256()
        print(f"Download {name}: {entry['version']}", flush=True)
        with urllib.request.urlopen(entry["url"], timeout=120) as response, target.open("wb") as output:
            while chunk := response.read(8 * 1024 * 1024):
                output.write(chunk)
                digest.update(chunk)
        if digest.hexdigest() != entry["sha256"]:
            target.unlink()
            raise RuntimeError(f"SHA-256 mismatch for {name}")
        installed[name] = entry
        return target

    def unpack_zip(name, target):
        source = archive(name)
        with tempfile.TemporaryDirectory(dir=root) as temporary:
            run("unzip", "-q", source, "-d", temporary)
            children = list(Path(temporary).iterdir())
            if len(children) != 1 or not children[0].is_dir():
                raise RuntimeError(f"Unexpected archive layout for {name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(children[0]), target)
        source.unlink()

    if args.mode == "apple":
        if platform.system() != "Darwin":
            raise RuntimeError("Apple runtime job requires macOS")
        source = archive("swift-macos")
        expanded = root / "swift"
        run("pkgutil", "--expand-full", source, expanded)
        candidates = list(expanded.glob("*/Payload/usr/bin/swift"))
        if len(candidates) != 1:
            raise RuntimeError("Unexpected Swift macOS package layout")
        swift = candidates[0]
        source.unlink()
    else:
        if platform.system() != "Linux" or platform.machine() != "x86_64":
            raise RuntimeError("Locked cross-runtime toolchain requires Ubuntu 24.04 x86_64")
        source = archive("swift-linux")
        run("tar", "-xzf", source, "-C", root)
        source.unlink()
        swift = root / "swift-6.4.0-RELEASE-ubuntu24.04/usr/bin/swift"
        source = archive("swift-" + args.mode)
        run(swift, "sdk", "install", source)
        source.unlink()
    environment = {"SWIFT_BIN": str(swift)}
    if args.mode == "android":
        sdk = root / "android-sdk"
        names = ["android-platform", "android-ndk", "android-build-tools", "android-command-tools", "android-platform-tools", "android-emulator", "android-image-" + args.api]
        for name in names:
            unpack_zip(name, sdk / artifacts[name]["sdkPath"])
        unpack_zip("gradle", root / "gradle")
        environment.update({
            "ANDROID_HOME": str(sdk), "ANDROID_SDK_ROOT": str(sdk),
            "ANDROID_NDK_HOME": str(sdk / "ndk/30.0.16248370"),
            "NDK_HOST": "linux-x86_64", "GRADLE_BIN": str(root / "gradle/bin/gradle"),
        })
        # Only licenses are accepted here; no floating SDK packages are installed.
        run(sdk / "cmdline-tools/19.0/bin/sdkmanager", f"--sdk_root={sdk}", "--licenses", input="y\n" * 100, text=True)
    run(swift, "--version")
    (root / "installed-inputs.json").write_text(json.dumps(installed, indent=2) + "\n")
    if github_env := os.environ.get("GITHUB_ENV"):
        with open(github_env, "a") as output:
            for key, value in environment.items():
                output.write(f"{key}={value}\n")
    print(json.dumps(environment, indent=2))


if __name__ == "__main__":
    main()
