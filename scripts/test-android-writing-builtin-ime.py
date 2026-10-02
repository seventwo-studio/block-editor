#!/usr/bin/env python3
"""Exercise the installed API26 LatinIME against shared-writing v4 in the existing job-owned runtime."""
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
              "sourceTree": run(["git", "rev-parse", "HEAD^{tree}"], timeout=30).decode().strip(),
              "runnerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "sourceDirty": bool(run(["git", "status", "--porcelain"], timeout=30).strip()),
              "apkSHA256": hashlib.sha256(args.apk.read_bytes()).hexdigest(),
              "scope": "Installed API26 LatinIME; explicit WritingSession v4 owner, physical Enter/Softbreak commits held draft and remote packet, mapped focus/caret, one-command author Undo/Redo and offline typed restore. Original Unicode/rich reference preservation; no process restart, structured paste, assets, TalkBack, general authoring or failed-repair acceptance."}
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

    modes = {"enter": "installedLatinImeCommitsBeforeSharedEnterAndKeepsAuthorUndo",
             "soft-break": "installedLatinImeCommitsBeforeSharedSoftBreakAndKeepsAuthorUndo"}
    stages = ("plain-keyboard", "plain-composing", "held-composing", "command-caret", "final-history", "final-state",
              "before-shared-command", "before-one-command-author-undo", "before-one-command-author-redo",
              "before-undo-structural-again", "before-undo-native-draft", "before-redo-native-draft", "before-redo-structural-command")
    try:
        if report["api"] != "26" or report["abi"] != "x86_64":
            raise RuntimeError("This CI acceptance row requires API26 x86_64")
        if report["settingsBefore"]["default_input_method"] not in (
                "com.android.inputmethod.latin/.LatinIME", "com.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME",
                "com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME"):
            raise RuntimeError("Existing preinstalled LatinIME required; never switch or download keyboards")
        report["keyboardPackage"] = report["settingsBefore"]["default_input_method"].split("/", 1)[0]
        (args.output / "keyboard-package.txt").write_text(shell("dumpsys", "package", report["keyboardPackage"]))
        report["installedTarget"] = shell("dumpsys", "package", "studio.seventwo.blockeditor.test")
        package_paths = shell("pm", "path", "studio.seventwo.blockeditor.test").splitlines()
        if len(package_paths) != 1 or not re.fullmatch(r"package:/data/app/[A-Za-z0-9_./=+~-]+\.apk", package_paths[0]):
            raise RuntimeError("Expected one installed test APK in /data/app")
        installed_apk = run(adb + ["exec-out", "cat", package_paths[0].removeprefix("package:")])
        report["installedAPK_SHA256"] = hashlib.sha256(installed_apk).hexdigest()
        if report["installedAPK_SHA256"] != report["apkSHA256"]:
            raise RuntimeError("Supplied test APK does not match installed input host")
        # Remove only this additive test's evidence; legacy system-ime files,
        # archives and installed keyboard settings are left untouched.
        owned = [f"writing-system-ime-{mode}-{suffix}.json" for mode in modes for suffix in ("proof", "control-states")]
        for mode in modes:
            for stage in stages:
                owned.extend([f"writing-system-ime-{mode}-{stage}.png", f"writing-system-ime-{mode}-{stage}-input-method.txt"])
        owned.extend("writing-system-ime-" + name + ".json" for name in ("keyboard-nodes", "key-touches"))
        run(adb + ["shell", "run-as", "studio.seventwo.blockeditor.test", "rm", "-f", *["files/" + name for name in owned]])
        report["executedTests"] = 0
        for mode, method in modes.items():
            instrument("WritingBuiltinImeTest", method, ["-e", "ciWritingSystemIme", "true"], mode + "-instrumentation.log")
            # Each opt-in method must execute exactly one successful test. The
            # instrumentation helper rejects assumptions/skips/status failures.
            report["executedTests"] += 1
            pull(f"writing-system-ime-{mode}-proof.json", mode + "-proof.json")
            proof = json.loads((args.output / (mode + "-proof.json")).read_text())
            assert proof["runID"] == report["runID"] and proof["mode"] == mode and proof["protocol"] == 4
            assert proof["passed"] is True
            assert proof["heldAccepted"] == proof["initialAccepted"]
            assert proof["heldReceipt"]["received"] == [] and len(proof["heldDeferred"]) == 1
            assert proof["composingDraft"]["reason"] == "Native composition is pending"
            assert proof["composingDraft"]["selectionStart"] == proof["composingDraft"]["selectionEnd"] == 3
            assert len(proof["committedReceipt"]["received"]) == 3
            assert proof["remoteOnlyUndoSnapshot"]["blocks"] == proof["remoteOnlySnapshot"]["blocks"]
            assert proof["failures"] == [] and proof["retainedDrafts"] == []
            assert proof["pendingDrafts"] == [] and proof["lastDeferred"] == [] and proof["lastRecovery"] is None
            for stage in ("plain-keyboard", "plain-composing", "held-composing", "command-caret", "final-history"):
                pull(f"writing-system-ime-{mode}-{stage}.png", mode + "-" + stage + ".png")
            pull(f"writing-system-ime-{mode}-control-states.json", mode + "-control-states.json")
        assert report["executedTests"] == 2
        report["passed"] = True
    except BaseException as error:
        report["failure"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        report["settingsAfter"] = settings()
        if report["settingsAfter"] != report["settingsBefore"]:
            report["passed"] = False
        collection_failures = []
        for mode in modes:
            for stage in stages:
                for suffix in (".png", "-input-method.txt"):
                    name = f"writing-system-ime-{mode}-{stage}{suffix}"
                    try: pull(name, mode + "-" + stage + suffix)
                    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, RuntimeError) as error:
                        collection_failures.append({"file": name, "error": f"{type(error).__name__}: {error}"})
            for kind in ("proof", "control-states"):
                name = f"writing-system-ime-{mode}-{kind}.json"
                try: pull(name, mode + "-" + kind + ".json")
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired, RuntimeError) as error:
                    collection_failures.append({"file": name, "error": f"{type(error).__name__}: {error}"})
        for name in ("keyboard-nodes", "key-touches"):
            try: pull("writing-system-ime-" + name + ".json", name + ".json")
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, RuntimeError) as error:
                collection_failures.append({"file": name + ".json", "error": f"{type(error).__name__}: {error}"})
        # Optional failure diagnostics must preserve the original test failure and
        # retain failure evidence. Screenshots remain mandatory in the success path.
        report["diagnosticCollectionFailures"] = collection_failures
        (args.output / "environment.json").write_text(json.dumps(report, indent=2) + "\n")
        if report["settingsAfter"] != report["settingsBefore"]:
            raise RuntimeError("System input settings changed; restore and investigate before accepting the run")


if __name__ == "__main__":
    main()
