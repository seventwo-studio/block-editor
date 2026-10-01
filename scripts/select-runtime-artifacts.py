#!/usr/bin/env python3
"""Select current-run artifact IDs without losing evidence from earlier attempts."""
from datetime import datetime
import json
import sys

names = ["runtime-swift", "runtime-wasm", "runtime-android-api26-x86_64",
         "runtime-android-api35-x86_64", "runtime-android-api35-arm64-v8a"]
run_id, revision = sys.argv[1:3]
pages = json.load(sys.stdin)
artifacts = [artifact for page in pages for artifact in page["artifacts"]]
selected = []
for name in names:
    candidates = [artifact for artifact in artifacts if artifact["name"] == name]
    if not candidates:
        raise SystemExit(f"Missing runtime artifact: {name}")
    dated = [(datetime.fromisoformat(artifact["created_at"].replace("Z", "+00:00")), artifact) for artifact in candidates]
    newest = max(date for date, _ in dated)
    latest = [artifact for date, artifact in dated if date == newest]
    if len(latest) != 1:
        raise SystemExit(f"Ambiguous latest runtime artifact: {name}")
    artifact = latest[0]
    origin = artifact["workflow_run"]
    if str(origin["id"]) != run_id or origin["head_sha"] != revision:
        raise SystemExit(f"Wrong run or source revision: {name}")
    if artifact["expired"] or artifact["size_in_bytes"] <= 0:
        raise SystemExit(f"Latest runtime artifact is expired or empty: {name}")
    if type(artifact["id"]) is not int or artifact["id"] <= 0:
        raise SystemExit(f"Invalid artifact ID: {name}")
    selected.append(str(artifact["id"]))
prefix = "ids=" if "--github-output" in sys.argv[3:] else ""
print(prefix + ",".join(selected))
