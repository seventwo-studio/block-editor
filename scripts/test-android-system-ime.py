#!/usr/bin/env python3
"""Opt-in installed-keyboard test; never substitutes an IME or an input connection."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import uuid
from datetime import datetime, timezone

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--serial", default=os.environ.get("ANDROID_SERIAL"), required=not os.environ.get("ANDROID_SERIAL"))
parser.add_argument("--sdk", default=os.environ.get("ANDROID_HOME"), required=not os.environ.get("ANDROID_HOME"))
parser.add_argument("--gradle", default=os.environ.get("GRADLE_BIN", "gradle"))
parser.add_argument("--phase", choices=["keyboard", "clipboard"], default="keyboard")
parser.add_argument("--keyboard-layout", choices=["gboard-japanese-qwerty-1080x2400"])
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
if args.phase == "keyboard" and not args.keyboard_layout:
    parser.error("--keyboard-layout is required for the keyboard phase")
if args.output.exists() and any(args.output.iterdir()):
    raise SystemExit("Use a new or empty evidence directory; never reuse an earlier acceptance result")
args.output.mkdir(parents=True, exist_ok=True)
adb = [str(Path(args.sdk) / "platform-tools/adb"), "-s", args.serial]

def run(command, **kwargs):
    return subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=kwargs.pop("timeout", 120), **kwargs).stdout

def shell(*command):
    return run(adb + ["shell", *command]).decode().strip()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

ime = shell("settings", "get", "secure", "default_input_method")
if ime != "com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME":
    raise SystemExit("The validated installed Gboard is required; this runner never changes keyboards")
if args.phase == "keyboard" and "1080x2400" not in shell("wm", "size"):
    raise SystemExit("The retained keyboard coordinates require the 1080x2400 layout")
abi = shell("getprop", "ro.product.cpu.abi")
if abi not in ("arm64-v8a", "x86_64"):
    raise SystemExit(f"Unsupported packaged ABI: {abi}")
source_files = run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "--", "Sources", "android/editor/src/main"], cwd=root).decode().splitlines()
source_hash = hashlib.sha256()
for name in sorted(set(source_files)):
    if not (root / name).is_file() or "jniLibs" in Path(name).parts:
        continue
    source_hash.update(name.encode() + b"\0" + (root / name).read_bytes() + b"\0")
report = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "revision": run(["git", "rev-parse", "HEAD"], cwd=root).decode().strip(),
    "dirty": bool(run(["git", "status", "--porcelain"], cwd=root).strip()),
    "productionSourceSHA256": source_hash.hexdigest(),
    "testSourceSHA256": digest(root / "android/editor/src/androidTest/java/studio/seventwo/blockeditor/SystemImeTest.kt"),
    "serial": args.serial, "api": shell("getprop", "ro.build.version.sdk"),
    "abi": abi, "fingerprint": shell("getprop", "ro.build.fingerprint"),
    "ime": ime, "keyboardLayout": args.keyboard_layout,
    "keyboardPackage": shell("dumpsys", "package", "com.google.android.inputmethod.latin"),
    "accessibilityServices": shell("settings", "get", "secure", "enabled_accessibility_services"),
    "jni": {p.name: digest(p) for p in (root / "android/editor/src/main/jniLibs" / abi).glob("*.so")},
    "scope": "System Japanese Gboard Kana composition, remote hold/commit, Unicode/marks/reference preservation, touched Undo/Redo and saved history reopen in a new host process; no TalkBack or full authoring acceptance",
}
if args.phase == "clipboard":
    report["scope"] = "Native plain Unicode paste with untrusted HTML alternative, local host bitmap touch, original rich/reference preservation and Undo; no composition or structured paste acceptance"
if not report["jni"]:
    raise SystemExit("Build the current native JNI engine first; no native libraries found")
(args.output / "environment.json").write_text(json.dumps(report, indent=2) + "\n")
run_id = str(uuid.uuid4())
report["runID"] = run_id
report["passed"] = False
def instrument(method, flags, log):
    result = run(adb + ["shell", "am", "instrument", "-w", "-r", "-e", "class",
                       f"studio.seventwo.blockeditor.SystemImeTest#{method}",
                       "-e", "nativeInputRun", run_id, *flags,
                       "studio.seventwo.blockeditor.test/androidx.test.runner.AndroidJUnitRunner"])
    (args.output / log).write_bytes(result)
    text = result.decode()
    print(text)
    if not re.search(r"OK \(1 test\)", text) or re.search(r"FAILURES!!!|INSTRUMENTATION_FAILED|Process crashed|INSTRUMENTATION_STATUS_CODE: -[234]", text):
        raise SystemExit(f"Native acceptance failed in {method}; retained diagnostics must be reviewed")

def pull(name, target):
    data = run(adb + ["exec-out", "run-as", "studio.seventwo.blockeditor.test", "cat", name], timeout=30)
    if target.endswith(".png") and not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise SystemExit(f"Invalid screenshot: {name}")
    (args.output / target).write_bytes(data)

try:
    try:
        build = run([args.gradle, "-p", str(root / "android"), f"-PblockEditorTestAbi={abi}", ":editor:assembleDebugAndroidTest"], cwd=root, timeout=600)
    except subprocess.CalledProcessError as error:
        (args.output / "build.log").write_bytes(error.stdout)
        raise
    (args.output / "build.log").write_bytes(build)
    apk = root / "android/editor/build/outputs/apk/androidTest/debug/editor-debug-androidTest.apk"
    report["testAPK_SHA256"] = digest(apk)
    run(adb + ["install", "-r", str(apk)])
    if args.phase == "clipboard":
        for name in ("system-ime-paste-proof.json", "system-ime-paste-menu.png", "system-ime-plain-paste.png"):
            run(adb + ["shell", "run-as", "studio.seventwo.blockeditor.test", "rm", "-f", "files/" + name])
        try:
            instrument("nativePlainPasteAndHostOwnedImage", ["-e", "nativeClipboard", "true"], "instrumentation.log")
        finally:
            for name in ("paste-menu", "plain-paste"):
                try: pull(f"files/system-ime-{name}.png", f"{name}.png")
                except subprocess.CalledProcessError: pass
        pull("files/system-ime-paste-proof.json", "proof.json")
        proof = json.loads((args.output / "proof.json").read_text())
        assert proof["hostImageTapped"] is True
        report["passed"] = True
    else:
        for name in ("before-caret", "after-caret", "keyboard", "composing", "author-undo", "author-redo", "process-reopen"):
            run(adb + ["shell", "run-as", "studio.seventwo.blockeditor.test", "rm", "-f", f"files/system-ime-{name}.png", f"files/system-ime-{name}-input-method.txt"])
        run(adb + ["shell", "run-as", "studio.seventwo.blockeditor.test", "rm", "-f", "files/system-ime-proof.json", "files/system-ime-reopen-proof.json"])
        try:
            instrument("installedJapaneseImeHoldsRemoteUntilKeyboardCommit",
                       ["-e", "systemIme", "true", "-e", "keyboardLayout", args.keyboard_layout], "instrumentation.log")
        finally:
            # Preserve partial diagnostics when an assertion fails; missing files are not success evidence.
            for name in ("before-caret", "after-caret", "keyboard", "composing", "author-undo", "author-redo"):
                for suffix in ("png", "input-method.txt"):
                    try:
                        pull(f"files/system-ime-{name}.{suffix}" if suffix == "png" else f"files/system-ime-{name}-{suffix}", f"{name}.{suffix}")
                    except subprocess.CalledProcessError:
                        pass
        pull("files/system-ime-proof.json", "proof.json")
        pull(f"files/native-input-{run_id}.json", "saved-history.json")
        run(adb + ["shell", "am", "force-stop", "studio.seventwo.blockeditor.test"])
        instrument("reopenSavedKeyboardDocumentInAnotherProcess", ["-e", "nativeInputReopen", "true"], "reopen-instrumentation.log")
        pull("files/system-ime-reopen-proof.json", "reopen-proof.json")
        pull("files/system-ime-process-reopen.png", "process-reopen.png")
        proof = json.loads((args.output / "proof.json").read_text())
        reopen = json.loads((args.output / "reopen-proof.json").read_text())
        assert proof["undoSnapshot"]["blocks"] == proof["remoteOnlyBlocks"]
        assert reopen["pid"] != reopen["previousPid"]
        assert reopen["snapshot"]["blocks"] == proof["committedSnapshot"]["blocks"]
        report["passed"] = True
    report["installedTarget"] = shell("dumpsys", "package", "studio.seventwo.blockeditor.test")
finally:
    (args.output / "environment.json").write_text(json.dumps(report, indent=2) + "\n")
    # Delete only this run's temporary archive. Keep the result even if the device goes away.
    try:
        run(adb + ["shell", "run-as", "studio.seventwo.blockeditor.test", "rm", "-f", f"files/native-input-{run_id}.json"], timeout=10)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        pass
