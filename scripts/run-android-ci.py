#!/usr/bin/env python3
"""Run packaged JNI fixtures on a pinned emulator and retain failure diagnostics."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("api", choices=["26", "35"])
    parser.add_argument("abi", choices=["x86_64", "arm64-v8a"])
    args = parser.parse_args()
    sdk = Path(os.environ["ANDROID_HOME"])
    output = Path("test-results/compatibility")
    output.mkdir(parents=True, exist_ok=True)
    label = f"android-api{args.api}-{args.abi}"
    adb = sdk / "platform-tools/adb"
    serial = "emulator-5554"
    runtime = Path(tempfile.mkdtemp(prefix="editor-android-runtime-", dir=os.environ.get("RUNNER_TEMP")))
    avd_home = runtime / "avd"
    avd_home.mkdir()
    # avdmanager and emulator use different fallback locations on hosted runners.
    # Share explicit job-owned paths instead of inheriting those defaults.
    environment = dict(os.environ, ANDROID_USER_HOME=str(runtime / "user"), ANDROID_AVD_HOME=str(avd_home))

    def run(*command, **kwargs):
        return subprocess.run([str(part) for part in command], check=True, env=environment, **kwargs)

    def device(*command, **kwargs):
        return run(adb, "-s", serial, *command, **kwargs)

    def instrument(class_name, filename, expected_tests):
        result = device("shell", "am", "instrument", "-w", "-r", "-e", "class", class_name,
                        "-e", "expectedAbi", args.abi, "studio.seventwo.blockeditor.test/androidx.test.runner.AndroidJUnitRunner",
                        capture_output=True, text=True, timeout=300)
        (output / filename).write_text(result.stdout + result.stderr)
        print(result.stdout, flush=True)
        # `am instrument` can exit zero even when its test process fails.
        match = re.search(r"OK \((\d+) tests?\)", result.stdout)
        if not match or int(match.group(1)) != expected_tests or "FAILURES!!!" in result.stdout:
            raise RuntimeError(f"Instrumentation did not execute {expected_tests} passing tests: {class_name}")

    run(os.environ["GRADLE_BIN"], "-p", "android", ":editor:assembleDebugAndroidTest", "--no-daemon", "--stacktrace",
        f"-PblockEditorTestAbi={args.abi}")
    apk = Path("android/editor/build/outputs/apk/androidTest/debug/editor-debug-androidTest.apk")
    with zipfile.ZipFile(apk) as package:
        abis = {name.split("/")[1] for name in package.namelist() if name.startswith("lib/") and name.endswith("libBlockEditorJNI.so")}
        if abis != {args.abi}:
            raise RuntimeError(f"APK must contain exactly the requested JNI ABI, found {abis}")
    avd = "block-editor-ci"
    run(sdk / "cmdline-tools/19.0/bin/avdmanager", "create", "avd", "--force", "--name", avd,
        "--path", avd_home / f"{avd}.avd", "--package", f"system-images;android-{args.api};google_apis;x86_64", input="no\n", text=True)
    listed = run(sdk / "emulator/emulator", "-list-avds", capture_output=True, text=True).stdout.splitlines()
    if avd not in listed:
        raise RuntimeError(f"Created AVD is not visible to the emulator: {listed}")
    (output / "avd-location.txt").write_text(f"ANDROID_USER_HOME={environment['ANDROID_USER_HOME']}\nANDROID_AVD_HOME={avd_home}\n")
    run(adb, "start-server")
    emulator_log = (output / "emulator.log").open("w")
    emulator = subprocess.Popen([str(sdk / "emulator/emulator"), "-avd", avd, "-port", "5554", "-no-window", "-no-audio",
                                 "-no-snapshot", "-no-boot-anim", "-wipe-data", "-accel", "on", "-gpu", "swiftshader_indirect",
                                 "-memory", "2048", "-cores", "2", "-camera-back", "none", "-camera-front", "none", "-no-metrics"],
                                stdout=emulator_log, stderr=subprocess.STDOUT, env=environment)
    try:
        deadline = time.monotonic() + 240
        while True:
            if emulator.poll() is not None:
                raise RuntimeError(f"Emulator exited before boot: {emulator.returncode}")
            boot = subprocess.run([str(adb), "-s", serial, "shell", "getprop", "sys.boot_completed"], capture_output=True, text=True, timeout=15)
            if boot.stdout.strip() == "1":
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("Emulator did not boot within 240 seconds")
            time.sleep(2)
        properties = device("shell", "getprop", capture_output=True, text=True).stdout
        (output / "device-properties.txt").write_text(properties)
        actual_api = device("shell", "getprop", "ro.build.version.sdk", capture_output=True, text=True).stdout.strip()
        actual_abis = device("shell", "getprop", "ro.product.cpu.abilist", capture_output=True, text=True).stdout.strip().split(",")
        if actual_api != args.api or args.abi not in actual_abis:
            raise RuntimeError(f"Unexpected Android runtime: API {actual_api}, ABIs {actual_abis}")
        device("shell", "input", "keyevent", "82")
        device("install", "-r", "--abi", args.abi, apk)
        instrument("studio.seventwo.blockeditor.RuntimeCompatibilityTest", "runtime-instrumentation.txt", 1)
        device("exec-out", "run-as", "studio.seventwo.blockeditor.test", "cat", "files/compatibility/android.json",
               stdout=(output / f"{label}.json").open("w"))
        device("exec-out", "run-as", "studio.seventwo.blockeditor.test", "cat", "files/compatibility/environment.json",
               stdout=(output / "android-environment.json").open("w"))
        metadata = json.loads((output / "android-environment.json").read_text())
        if metadata["api"] != int(args.api) or metadata["jniAbi"] != args.abi:
            raise RuntimeError("Instrumented JNI environment does not match the requested runtime")
        instrument("studio.seventwo.blockeditor.CompatibilityTest", "compatibility-instrumentation.txt", 8)
    finally:
        try:
            diagnostics = [("logcat.txt", ["logcat", "-d"])]
            # Partial fixture output remains useful when an assertion fails.
            if not (output / f"{label}.json").exists():
                diagnostics.append((f"{label}.json", ["exec-out", "run-as", "studio.seventwo.blockeditor.test", "cat", "files/compatibility/android.json"]))
            for filename, command in diagnostics:
                with (output / filename).open("w") as log:
                    try:
                        subprocess.run([str(adb), "-s", serial, *command], stdout=log, stderr=subprocess.STDOUT, timeout=20, env=environment)
                    except (subprocess.TimeoutExpired, OSError) as error:
                        log.write(f"\nDiagnostic collection failed: {error}\n")
        finally:
            emulator.terminate()
            try:
                emulator.wait(timeout=15)
            except subprocess.TimeoutExpired:
                emulator.kill()
                emulator.wait()
            emulator_log.close()


if __name__ == "__main__":
    main()
