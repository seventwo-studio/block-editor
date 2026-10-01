#!/usr/bin/env python3
"""Exercise the installed API26 AOSP keyboard in an existing, job-owned runtime."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import uuid
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", default=os.environ.get("ANDROID_HOME"), required=not os.environ.get("ANDROID_HOME"))
    parser.add_argument("--serial", required=True)
    parser.add_argument("--apk", type=Path, required=True, help="Already installed packaged test APK; this runner never builds or installs")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if args.output.exists() and any(args.output.iterdir()):
        raise SystemExit("Use a new or empty evidence directory")
    args.output.mkdir(parents=True, exist_ok=True)
    adb = [str(Path(args.sdk) / "platform-tools/adb"), "-s", args.serial]

    def run(command, timeout=120):
        return subprocess.run(command, cwd=root, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=timeout).stdout

    def shell(*command):
        return run(adb + ["shell", *command]).decode().strip()

    def settings():
        return {key: shell("settings", "get", "secure", key) for key in
                ("default_input_method", "selected_input_method_subtype", "enabled_accessibility_services")}

    report = {"passed": False, "timestamp": datetime.now(timezone.utc).isoformat(),
              "runID": str(uuid.uuid4()), "serial": args.serial, "settingsBefore": settings(),
              "api": shell("getprop", "ro.build.version.sdk"), "abi": shell("getprop", "ro.product.cpu.abi"),
              "fingerprint": shell("getprop", "ro.build.fingerprint"),
              "sourceCommit": run(["git", "rev-parse", "HEAD"], timeout=30).decode().strip(),
              "sourceDirty": bool(run(["git", "status", "--porcelain"], timeout=30).strip()),
              "apkSHA256": hashlib.sha256(args.apk.read_bytes()).hexdigest(),
              "scope": "Installed API26 LatinIME; actual composition/remote hold, mapped caret, separate rich Unicode/reference preservation, author Undo/Redo, real process reopen and native plain paste/local host bitmap. No TalkBack, structured paste or full authoring acceptance."}
    sources = run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "--", "Sources", "android/editor/src/main"], timeout=30).decode().splitlines()
    digest = hashlib.sha256()
    for name in sorted(set(sources)):
        if not (root / name).is_file() or "jniLibs" in Path(name).parts:
            continue
        digest.update(name.encode() + b"\0" + (root / name).read_bytes() + b"\0")
    report["productionSourceSHA256"] = digest.hexdigest()
    report["testSourcesSHA256"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in
                                  (root / "android/editor/src/androidTest/java/studio/seventwo/blockeditor").glob("*ImeTest.kt")}
    with zipfile.ZipFile(args.apk) as archive:
        report["packagedJNI_SHA256"] = {name: hashlib.sha256(archive.read(name)).hexdigest() for name in archive.namelist()
                                       if name.startswith("lib/") and name.endswith(".so")}

    def pull(name, destination):
        data = run(adb + ["exec-out", "run-as", "studio.seventwo.blockeditor.test", "cat", "files/" + name], timeout=30)
        if destination.endswith(".png") and not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise RuntimeError("Invalid screenshot: " + name)
        (args.output / destination).write_bytes(data)

    def instrument(class_name, method, flags, log):
        command = adb + ["shell", "am", "instrument", "-w", "-r", "-e", "class",
                         f"studio.seventwo.blockeditor.{class_name}#{method}",
                         "-e", "nativeInputRun", report["runID"], *flags,
                         "studio.seventwo.blockeditor.test/androidx.test.runner.AndroidJUnitRunner"]
        try:
            data = run(command, timeout=180)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            (args.output / log).write_bytes(error.stdout or b"")
            raise
        (args.output / log).write_bytes(data)
        result = data.decode()
        print(result, flush=True)
        if not re.search(r"OK \(1 test\)", result) or re.search(
                r"FAILURES!!!|INSTRUMENTATION_FAILED|Process crashed|INSTRUMENTATION_STATUS_CODE: -[234]", result):
            raise RuntimeError("Failed or skipped real system input: " + method)

    archive_name = f"native-input-{report['runID']}.json"
    try:
        if report["api"] != "26" or report["abi"] != "x86_64":
            raise RuntimeError("This CI acceptance row requires API26 x86_64")
        if report["settingsBefore"]["default_input_method"] not in (
                "com.android.inputmethod.latin/.LatinIME", "com.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME"):
            raise RuntimeError("Existing AOSP LatinIME required; never switch or download keyboards")
        (args.output / "keyboard-package.txt").write_text(shell("dumpsys", "package", "com.android.inputmethod.latin"))
        report["installedTarget"] = shell("dumpsys", "package", "studio.seventwo.blockeditor.test")
        package_paths = shell("pm", "path", "studio.seventwo.blockeditor.test").splitlines()
        if len(package_paths) != 1 or not re.fullmatch(r"package:/data/app/[A-Za-z0-9_./=+~-]+\.apk", package_paths[0]):
            raise RuntimeError("Expected one installed test APK in /data/app")
        installed_apk = run(adb + ["exec-out", "cat", package_paths[0].removeprefix("package:")])
        report["installedAPK_SHA256"] = hashlib.sha256(installed_apk).hexdigest()
        if report["installedAPK_SHA256"] != report["apkSHA256"]:
            raise RuntimeError("Supplied test APK does not match installed input host")
        # Remove only test-owned evidence to prevent an earlier proof from masquerading as this run.
        owned = ["system-ime-proof.json", "system-ime-reopen-proof.json", "system-ime-paste-proof.json"]
        for name in ("plain-keyboard", "plain-composing", "composing", "author-undo", "author-redo", "process-reopen", "paste-menu", "plain-paste"):
            owned.extend(["system-ime-" + name + ".png", "system-ime-" + name + "-input-method.txt"])
        owned.extend("system-ime-" + name + ".json" for name in ("keyboard-nodes", "key-touches", "plain-updates"))
        run(adb + ["shell", "run-as", "studio.seventwo.blockeditor.test", "rm", "-f", *["files/" + n for n in owned]])
        instrument("BuiltinImeTest", "installedLatinImeHoldsRemoteAndPreservesAuthorHistory",
                   ["-e", "ciSystemIme", "true"], "instrumentation.log")
        pull("system-ime-proof.json", "proof.json")
        pull(archive_name, "saved-history.json")
        run(adb + ["shell", "am", "force-stop", "studio.seventwo.blockeditor.test"])
        instrument("SystemImeTest", "reopenSavedKeyboardDocumentInAnotherProcess",
                   ["-e", "nativeInputReopen", "true"], "reopen-instrumentation.log")
        pull("system-ime-reopen-proof.json", "reopen-proof.json")
        instrument("SystemImeTest", "nativePlainPasteAndHostOwnedImage",
                   ["-e", "nativeClipboard", "true"], "paste-instrumentation.log")
        pull("system-ime-paste-proof.json", "paste-proof.json")
        proof = json.loads((args.output / "proof.json").read_text())
        reopen = json.loads((args.output / "reopen-proof.json").read_text())
        saved = json.loads((args.output / "saved-history.json").read_text())
        paste = json.loads((args.output / "paste-proof.json").read_text())
        assert proof["runID"] == report["runID"]
        assert proof["heldSync"]["received"] == []
        assert proof["undoSnapshot"]["blocks"] == proof["remoteOnlyBlocks"]
        assert reopen["previousPid"] == saved["pid"] and reopen["pid"] != reopen["previousPid"]
        assert reopen["snapshot"]["blocks"] == proof["committedSnapshot"]["blocks"] == saved["expectedBlocks"]
        assert paste["hostImageTapped"] is True
        for name in ("plain-keyboard", "plain-composing", "composing", "author-undo", "author-redo", "process-reopen", "paste-menu", "plain-paste"):
            pull("system-ime-" + name + ".png", name + ".png")
        report["passed"] = True
    except BaseException as error:
        report["failure"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        report["settingsAfter"] = settings()
        if report["settingsAfter"] != report["settingsBefore"]:
            report["passed"] = False
        (args.output / "environment.json").write_text(json.dumps(report, indent=2) + "\n")
        for name in ("plain-keyboard", "plain-composing", "composing", "author-undo", "author-redo", "process-reopen", "paste-menu", "plain-paste"):
            for suffix, destination in ((".png", name + ".png"), ("-input-method.txt", name + "-input-method.txt")):
                try: pull("system-ime-" + name + suffix, destination)
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired): pass
        for name in ("keyboard-nodes", "key-touches", "plain-updates"):
            try: pull("system-ime-" + name + ".json", name + ".json")
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired): pass
        try: run(adb + ["shell", "run-as", "studio.seventwo.blockeditor.test", "rm", "-f", "files/" + archive_name], timeout=10)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired): pass
        if report["settingsAfter"] != report["settingsBefore"]:
            raise RuntimeError("System input settings changed; restore and investigate before accepting the run")


if __name__ == "__main__":
    main()
