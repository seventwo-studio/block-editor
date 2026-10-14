"""Fail-closed locked downloads with retained transport/integrity evidence."""
import hashlib
import http.client
import json
from pathlib import Path
import socket
import ssl
import time
import urllib.error
import urllib.request


def download(entry, target, name, evidence, sleep=time.sleep):
    target = Path(target)
    expected_size = entry.get("size")
    for attempt in range(1, 4):
        digest, count = hashlib.sha256(), 0
        status, length, range_header, content_type = None, None, None, None
        retryable, error, retry_after = False, None, 0
        headers = {"Accept-Encoding": "identity"}
        if attempt > 1:
            headers.update({"Cache-Control": "no-cache", "Pragma": "no-cache"})
        try:
            request = urllib.request.Request(entry["url"], headers=headers)
            with urllib.request.urlopen(request, timeout=120) as response, target.open("xb") as output:
                status = response.status
                length = response.headers.get("Content-Length")
                range_header = response.headers.get("Content-Range")
                content_type = response.headers.get("Content-Type", "").split(";", 1)[0].lower()
                transfer_size = expected_size if expected_size is not None else int(length) if length and length.isdigit() else None
                while chunk := response.read(8 * 1024 * 1024):
                    output.write(chunk); digest.update(chunk); count += len(chunk)
                if status == 206 or range_header:
                    retryable, error = True, "Unexpected partial response to a full archive request"
                elif status != 200:
                    error = f"Unexpected HTTP status {status}"
                elif content_type in {"text/html", "text/plain", "application/json", "application/xml"}:
                    error = f"Unexpected archive content type {content_type}"
                elif transfer_size is not None and count < transfer_size:
                    retryable, error = True, f"Truncated archive: {count} of {transfer_size} bytes"
                elif expected_size is not None and count != expected_size:
                    error = f"Archive size mismatch: {count} versus {expected_size} bytes"
                elif digest.hexdigest() != entry["sha256"]:
                    error = "Complete archive SHA-256 mismatch"
        except urllib.error.HTTPError as failure:
            status = failure.code
            retryable = status in {408, 429, 500, 502, 503, 504}
            error = f"HTTP error {status}"
            value = failure.headers.get("Retry-After", "0")
            retry_after = int(value) if value.isdigit() else 0
        except (urllib.error.URLError, TimeoutError, socket.timeout, http.client.IncompleteRead, ConnectionError) as failure:
            retryable, error = True, f"Transport error: {type(failure).__name__}"
            if isinstance(failure, urllib.error.URLError) and isinstance(failure.reason, ssl.SSLCertVerificationError):
                retryable = False
            if isinstance(failure, http.client.IncompleteRead) and failure.partial:
                with target.open("ab") as output: output.write(failure.partial)
                digest.update(failure.partial); count += len(failure.partial)
        if error is None:
            outcome = "verified"
            rejected = None
        else:
            outcome = "rejected"
            rejected = target.with_name(target.name + f".rejected-{attempt}")
            if target.exists(): target.rename(rejected)
        receipt = {"artifact": name, "attempt": attempt, "expectedSHA256": entry["sha256"],
                   "actualSHA256": digest.hexdigest(), "expectedBytes": expected_size, "receivedBytes": count,
                   "httpStatus": status, "contentLength": length, "contentRange": range_header,
                   "contentType": content_type, "freshCacheRequest": attempt > 1,
                   "outcome": outcome, "error": error, "retryable": retryable,
                   "rejectedFile": rejected.name if rejected and rejected.exists() else None}
        with Path(evidence).open("a") as log: log.write(json.dumps(receipt) + "\n")
        if error is None: return target
        if not retryable or attempt == 3:
            raise RuntimeError(f"Locked download failed for {name} after {attempt} attempt(s): {error}")
        sleep(max(2 if attempt == 1 else 5, retry_after))
