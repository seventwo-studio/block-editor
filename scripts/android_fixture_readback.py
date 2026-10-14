"""Copy immutable task fixture files with complete-byte verification.

ADB can close a transport during exec-out, including after an exit-zero partial
read. Retry only unknown empty exit-255 outcomes or a verified byte mismatch;
permission, missing-file, malformed-source and other errors remain failures.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time


def read_fixture(device, remote, destination, sleep=time.sleep):
    if not re.fullmatch(r"files/(compatibility|resource|performance|assessment-capture)/[A-Za-z0-9_.-]+", remote):
        raise ValueError("Not an owned fixture path")
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    attempts = []
    receipt = destination.with_name(destination.name + ".readback.json")
    for number in range(1, 4):
        record = {"attempt": number, "remote": remote, "passed": False}
        attempts.append(record)
        retry = False
        data = None
        try:
            digest = device("shell", "run-as", "studio.seventwo.blockeditor.test", "sha256sum", remote,
                            capture_output=True, timeout=60)
            match = re.fullmatch(rb"([0-9a-f]{64})[ \t]+[ *]?" + re.escape(remote.encode()) + rb"\s*", digest.stdout)
            if not match or digest.stderr:
                raise ValueError("Invalid remote fixture digest readback")
            expected = match.group(1).decode("ascii")
            readback = device("exec-out", "run-as", "studio.seventwo.blockeditor.test", "cat", remote,
                              capture_output=True, timeout=60)
            data = readback.stdout
            if readback.stderr:
                destination.with_name(destination.name + f".attempt-{number}.stderr").write_bytes(readback.stderr)
                raise ValueError("Unexpected fixture read error output")
            actual = hashlib.sha256(data).hexdigest()
            record.update(expectedSHA256=expected, actualSHA256=actual, byteCount=len(data))
            if actual != expected:
                retry = True
                raise RuntimeError("Fixture readback bytes differ from the immutable remote file")
            # Syntax checks do not normalize or replace the retained bytes.
            if remote.endswith(".json"):
                json.loads(data)
            temporary = destination.with_name(destination.name + ".readback.tmp")
            temporary.write_bytes(data)
            temporary.replace(destination)
            record["passed"] = True
            return data
        except subprocess.CalledProcessError as failure:
            output = failure.stdout or b""
            error = failure.stderr or b""
            record.update(exitCode=failure.returncode, stdoutBytes=len(output), stderrBytes=len(error))
            destination.with_name(destination.name + f".attempt-{number}.stdout").write_bytes(output)
            destination.with_name(destination.name + f".attempt-{number}.stderr").write_bytes(error)
            retry = failure.returncode == 255 and not output and not error
            record["failure"] = "ADB fixture command failed"
            if not retry or number == 3:
                raise
        except Exception as failure:
            if data is not None:
                destination.with_name(destination.name + f".attempt-{number}.partial").write_bytes(data)
            record["failure"] = str(failure)
            if not retry or number == 3:
                raise
        finally:
            receipt.write_text(json.dumps({"passed": record["passed"], "attempts": attempts}, indent=2) + "\n")
        sleep(2 if number == 1 else 5)
