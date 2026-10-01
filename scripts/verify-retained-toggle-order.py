#!/usr/bin/env python3
"""Independent public JSON witness for retained own undo/redo packet ordering."""
import argparse, hashlib, json, pathlib, subprocess
parser = argparse.ArgumentParser()
parser.add_argument("bridge")
parser.add_argument("--output", required=True)
parser.add_argument("--expect-fixed", action="store_true")
args = parser.parse_args()
results = []
for version in (1, 2, 3):
    for reversed_order in (False, True):
        p = subprocess.Popen([args.bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        transcript = []
        def call(command, session="stopped", **fields):
            request = dict(command=command, session=session, **fields)
            p.stdin.write(json.dumps(request) + "\n")
            p.stdin.flush()
            response = json.loads(p.stdout.readline())
            transcript.append(dict(request=request, response=response))
            return response
        try:
            call("create", actorID="a", documentID="retained-order", epoch="v3", collaborationVersion=version,
                 blocks=[{"id":"left", "type":"paragraph", "content":[{"type":"text", "text":"a", "marks":[]}]}])
            call("replaceText", address={"blockID":"left", "path":["content"]}, start=1, end=1, text="X")
            accepted = call("save")["value"]
            call("undo")
            call("redo")
            batch = call("changes")["value"]
            call("close")
            call("restore", "resumed", actorID="a", snapshot=accepted)
            redo = dict(batch, changes=[c for c in batch["changes"] if c["id"]["counter"] == 3])
            undo = dict(batch, changes=[c for c in batch["changes"] if c["id"]["counter"] == 2])
            packets = [redo, undo] if reversed_order else [undo, redo]
            for packet in packets + packets:
                call("receive", "resumed", batch=packet)
            current = call("document", "resumed")
            saved = call("save", "resumed")
            reopened = call("restore", "reopened", actorID="a", snapshot=saved["value"])
            undone = call("undo", "reopened") if reopened.get("ok") else None
            value = current.get("value", {})
            expected_blocks = [{"id":"left", "type":"paragraph", "content":[{"type":"text", "text":"aX", "marks":[]}]}]
            good = all(step["response"].get("ok") is True for step in transcript)
            good = good and value.get("blocks") == expected_blocks
            good = good and value.get("canUndo") is True and value.get("canRedo") is False
            good = good and reopened.get("ok") and reopened["value"] == value
            good = good and undone.get("ok") and undone["value"]["blocks"][0]["content"][0]["text"] == "a"
            results.append(dict(version=version, delivery="redo-before-undo" if reversed_order else "undo-before-redo",
                                passed=bool(good), transcript=transcript))
        finally:
            p.stdin.close()
            p.wait()
bridge = pathlib.Path(args.bridge)
evidence = dict(bridgeSHA256=hashlib.sha256(bridge.read_bytes()).hexdigest(), cases=results)
pathlib.Path(args.output).write_text(json.dumps(evidence, indent=2) + "\n")
print(json.dumps(dict(bridgeSHA256=evidence["bridgeSHA256"], cases=[{k:v for k,v in r.items() if k != "transcript"} for r in results])))
if args.expect_fixed and not all(r["passed"] for r in results):
    raise SystemExit(1)
