#!/usr/bin/env python3
"""Opt-in installed TalkBack gestures; restore original accessibility preferences."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--sdk", default=os.environ.get("ANDROID_HOME"), required=not os.environ.get("ANDROID_HOME"))
parser.add_argument("--serial", default=os.environ.get("ANDROID_SERIAL"), required=not os.environ.get("ANDROID_SERIAL"))
parser.add_argument("--apk", type=Path, required=True, help="Already built and installed test host; no build or install")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
if args.output.exists() and any(args.output.iterdir()):
    raise SystemExit("Use a new or empty evidence directory")
args.output.mkdir(parents=True, exist_ok=True)
adb = [str(Path(args.sdk) / "platform-tools/adb"), "-s", args.serial]

def run(command, timeout=30):
    return subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout).stdout

def shell(*command):
    return run(adb + ["shell", *command]).decode().strip()

keys = ("enabled_accessibility_services", "accessibility_enabled", "touch_exploration_enabled")
original = {key: shell("settings", "get", "secure", key) for key in keys}
service = "com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService"
report = {"passed": False, "settingsBefore": original,
          "api": shell("getprop", "ro.build.version.sdk"), "abi": shell("getprop", "ro.product.cpu.abi"),
          "fingerprint": shell("getprop", "ro.build.fingerprint"),
          "apkSHA256": hashlib.sha256(args.apk.read_bytes()).hexdigest(),
          "talkbackTestSourceSHA256": hashlib.sha256((root / "android/editor/src/androidTest/java/studio/seventwo/blockeditor/TalkBackInputTest.kt").read_bytes()).hexdigest(),
          "scope": "Installed TalkBack retained with FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES; real swipe focus and double-tap author Undo. Spoken audio/full editor accessibility remain open."}
changed = False
gesture_trace = []

def kernel_gesture(request):
    # Emulator console events enter the guest kernel's real touchscreen device.
    # Axis ranges below are verified against this pinned emulator before use.
    width, height = request["width"], request["height"]
    assert type(request["sequence"]) is int and 1 <= request["sequence"] <= 21
    assert width == 1080 and height == 2400
    x = round(request["x"] * 32767 / (width - 1))
    y = round(request["y"] * 32767 / (height - 1))
    end_x = round(request["endX"] * 32767 / (width - 1))
    assert all(0 <= value <= 32767 for value in (x, y, end_x))
    assert request["kind"] in ("swipe", "double-tap")
    def event(*values):
        output = run(adb + ["emu", "event", "send", *values])
        if b"OK" not in output or b"KO:" in output:
            raise RuntimeError("Emulator rejected touchscreen event")
        gesture_trace.append({"sequence": request["sequence"], "events": values})
    def release():
        event("EV_ABS:ABS_MT_TRACKING_ID:-1", "EV_ABS:ABS_MT_PRESSURE:0", "EV_KEY:BTN_TOUCH:0", "EV_SYN:0:0")
    for tap in range(2 if request["kind"] == "double-tap" else 1):
        try:
            event("EV_ABS:ABS_MT_SLOT:0", f"EV_ABS:ABS_MT_TRACKING_ID:{request['sequence'] * 2 + tap}",
                  f"EV_ABS:ABS_MT_POSITION_X:{x}", f"EV_ABS:ABS_MT_POSITION_Y:{y}",
                  "EV_ABS:ABS_MT_PRESSURE:50", "EV_ABS:ABS_MT_TOOL_TYPE:0", "EV_KEY:BTN_TOUCH:1", "EV_SYN:0:0")
            if request["kind"] == "swipe":
                for step in range(1, 7):
                    time.sleep(.02)
                    event(f"EV_ABS:ABS_MT_POSITION_X:{round(x + (end_x - x) * step / 6)}", "EV_SYN:0:0")
            else:
                time.sleep(.03)
        finally:
            release()
        if tap == 0 and request["kind"] == "double-tap":
            time.sleep(.06)

try:
    if report["api"] != "35" or report["abi"] != "arm64-v8a":
        raise RuntimeError("This reviewed TalkBack row requires the existing API35 ARM64 emulator")
    devices = shell("getevent", "-lp")
    (args.output / "kernel-input-devices.txt").write_text(devices)
    primary = devices.split("name:     \"virtio_input_multi_touch_1\"", 1)[1].split("add device", 1)[0]
    for axis in ("ABS_MT_POSITION_X", "ABS_MT_POSITION_Y"):
        assert re.search(axis + r"\s*: value \d+, min 0, max 32767,", primary)
    report["gestureSource"] = "emulator-kernel-touchscreen"
    if not shell("pm", "path", "com.google.android.marvin.talkback").startswith("package:"):
        raise RuntimeError("Use the already installed TalkBack; no downloads")
    package = shell("pm", "path", "studio.seventwo.blockeditor.test")
    if not re.fullmatch(r"package:/data/app/[A-Za-z0-9_./=+~-]+\.apk", package):
        raise RuntimeError("Expected exactly one installed test APK")
    installed = run(adb + ["exec-out", "cat", package.removeprefix("package:")])
    report["installedAPK_SHA256"] = hashlib.sha256(installed).hexdigest()
    if report["installedAPK_SHA256"] != report["apkSHA256"]:
        raise RuntimeError("Installed APK differs from the supplied test host")
    (args.output / "talkback-package.txt").write_text(shell("dumpsys", "package", "com.google.android.marvin.talkback"))
    (args.output / "accessibility-before.txt").write_text(shell("dumpsys", "accessibility"))
    run(adb + ["shell", "run-as", "studio.seventwo.blockeditor.test", "rm", "-f",
               "files/talkback-input-proof.json", "files/talkback-undo-focus.png", "files/talkback-activated-undo.png", "files/talkback-final-focus.png",
               "files/talkback-gesture-request.json", "files/talkback-gesture-ack.txt"])
    services = [] if original["enabled_accessibility_services"] in ("null", "") else original["enabled_accessibility_services"].split(":")
    if service not in services:
        services.append(service)
    changed = True
    shell("settings", "put", "secure", "enabled_accessibility_services", ":".join(services))
    shell("settings", "put", "secure", "accessibility_enabled", "1")
    time.sleep(2)
    (args.output / "accessibility-enabled.txt").write_text(shell("dumpsys", "accessibility"))
    command = adb + ["shell", "am", "instrument", "-w", "-r", "-e", "class",
                     "studio.seventwo.blockeditor.TalkBackInputTest#installedTalkBackFocusesAndActivatesAuthorUndo",
                     "-e", "nativeTalkBack", "true", "-e", "nativeTalkBackKernel", "true",
                     "studio.seventwo.blockeditor.test/androidx.test.runner.AndroidJUnitRunner"]
    with (args.output / "instrumentation.log").open("wb") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        last_sequence = 0
        deadline = time.monotonic() + 120
        try:
            while process.poll() is None:
                if time.monotonic() > deadline:
                    raise RuntimeError("TalkBack instrumentation timed out")
                try:
                    request = json.loads(run(adb + ["exec-out", "run-as", "studio.seventwo.blockeditor.test", "cat", "files/talkback-gesture-request.json"]))
                except (subprocess.CalledProcessError, json.JSONDecodeError):
                    time.sleep(.1)
                    continue
                if request["sequence"] > last_sequence:
                    kernel_gesture(request)
                    last_sequence = request["sequence"]
                    shell("run-as", "studio.seventwo.blockeditor.test", "sh", "-c",
                          f"'echo {last_sequence} > files/talkback-gesture-ack.txt'")
                time.sleep(.1)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
                shell("am", "force-stop", "studio.seventwo.blockeditor.test")
    result = (args.output / "instrumentation.log").read_bytes()
    print(result.decode(), flush=True)
    if process.returncode or not re.search(rb"OK \(1 test\)", result) or re.search(
            rb"FAILURES!!!|INSTRUMENTATION_FAILED|Process crashed|INSTRUMENTATION_STATUS_CODE: -[234]", result):
        raise RuntimeError("TalkBack gesture acceptance failed or skipped")
    proof = json.loads(run(adb + ["exec-out", "run-as", "studio.seventwo.blockeditor.test", "cat", "files/talkback-input-proof.json"]))
    assert proof["passed"] is True and proof["originalBlocks"] == proof["undoSnapshot"]["blocks"]
    report["passed"] = True
finally:
    (args.output / "kernel-gesture-events.json").write_text(json.dumps(gesture_trace, indent=2) + "\n")
    for name in ("input-proof.json", "undo-focus.png", "activated-undo.png", "final-focus.png"):
        try:
            data = run(adb + ["exec-out", "run-as", "studio.seventwo.blockeditor.test", "cat", "files/talkback-" + name])
            (args.output / name).write_bytes(data)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass
    try:
        (args.output / "accessibility-after-test.txt").write_text(shell("dumpsys", "accessibility"))
    finally:
        if changed:
            for key, value in original.items():
                shell("settings", "delete", "secure", key) if value == "null" else shell("settings", "put", "secure", key, value)
        report["settingsAfter"] = {key: shell("settings", "get", "secure", key) for key in keys}
        if report["settingsAfter"] != original:
            report["passed"] = False
        (args.output / "environment.json").write_text(json.dumps(report, indent=2) + "\n")
        if report["settingsAfter"] != original:
            raise RuntimeError("Restore original accessibility preferences before accepting the run")
