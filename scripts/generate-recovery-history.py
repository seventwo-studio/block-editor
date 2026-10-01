#!/usr/bin/env python3
"""Independent recovery expectations. Never ask the engine to construct an oracle."""
import copy
import json
import sys
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "tests/BlockEditorCoreTests/Fixtures/recovery.json"
fixture = json.loads(path.read_text())
fixture["steps"] = [row for row in fixture["steps"] if "recoveryCampaign" not in row]
fixture["equal"] = [pair for pair in fixture["equal"] if not pair[0].startswith("recovery-generated-")]
fixture["expectedBlocks"] = {key: value for key, value in fixture.get("expectedBlocks", {}).items() if not key.startswith("recovery-generated-")}
seeds = [1, 7, 42, 255]

def text(value, marks=None):
    return {"type": "text", "text": value, "marks": marks or []}

def toggle(label, children=None):
    return {"id": label, "type": "toggle", "summary": [text(label)], "children": children or []}

def baseline(label, path=None):
    return {"baseline": {"blockID": label, "path": path or []}}

def collection(label=None, path=None):
    return {"field": "children" if label else "blocks", **({"owner": baseline(label, path)} if label else {})}

for kind, values in [("collision", seeds), ("depth", [17, 20, 22])]:
    for seed in values:
        key = f"recovery-generated-{kind}-{seed}"
        def step(command, actor="a", capture=None, expected=None, bindings=None, error=None, **input):
            row = {"recoveryCampaign": key, "request": {"command": command, "session": f"{key}-{actor}", **copy.deepcopy(input)}}
            if capture:
                row["capture"] = f"{key}-{capture}"
                if expected is not None:
                    fixture["expectedBlocks"][row["capture"]] = copy.deepcopy(expected)
            if bindings:
                row["bindings"] = {name: [f"{key}-{value[0]}", *value[1:]] if isinstance(value, list) else f"{key}-{value}" for name, value in bindings.items()}
            if error:
                row["error"] = error
            fixture["steps"].append(row)
        def equal(left, right):
            fixture["equal"].append([f"{key}-{left}", f"{key}-{right}"])
        if kind == "collision":
            blocks = [toggle("parent"), toggle("destination")]
            payloads = [{"id": "same", "type": "paragraph", "content": [text(f"{actor} café 👩🏽‍💻 {seed}", [{"type": "italic"}]),
                {"type": "entity-ref", "entityId": f"{actor}-{seed}", "entityType": "note", "label": "Ref"}],
                "host": {"id": "opaque", "keep": True}} for actor in ["a", "b"]]
            for actor, value in zip(["a", "b"], payloads):
                step("create", actor, documentID=key, actorID=actor, collaborationVersion=2, blocks=blocks)
                step("insertNode", actor, value=value, collection=collection("parent"))
                step("changes", actor, capture=f"batch-{actor}")
            second = {"inserted": {"creation": {"change": {"actor": "b", "counter": 1}, "index": 0}, "path": []}}
            repairs = [[{"move": {"identity": second, "collection": collection("destination")}}],
                       [{"wrap": {"identity": second, "container": toggle(f"wrapper-{seed}"), "field": "children"}}]]
            both = [toggle(f"wrapper-{seed}", [payloads[1]]), toggle("parent", [payloads[0]]), toggle("destination")]
        else:
            def chain(prefix):
                node = {"id": "leaf", "type": "paragraph", "content": [text(f"{prefix} café", [{"type": "italic"}]),
                    {"type": "entity-ref", "entityId": prefix, "entityType": "note", "label": "Ref"}]}
                for index in reversed(range(seed)):
                    node = toggle(f"{prefix}-{index}", [node])
                return node
            blocks = [chain(prefix) for prefix in ["A", "B", "C"]]
            deep = lambda prefix: [part for i in range(1, seed) for part in ["children", f"{prefix}-{i}"]]
            for actor, moved, destination in [("a", "A", "B"), ("b", "B", "C")]:
                step("create", actor, documentID=key, actorID=actor, collaborationVersion=2, blocks=blocks)
                step("moveNode", actor, identity=baseline(f"{moved}-0"), collection=collection(f"{destination}-0", deep(destination)))
                step("changes", actor, capture=f"batch-{actor}")
            repairs = [[{"move": {"identity": baseline("A-0"), "collection": collection()}}]] * 2
            both = [copy.deepcopy(blocks[0]), copy.deepcopy(blocks[2])]
            parent = both[1]
            for _ in range(seed - 1):
                parent = parent["children"][0]
            parent["children"].insert(0, copy.deepcopy(blocks[1]))
        for actor, peer in [("a", "b"), ("b", "a")]:
            step("save", actor, capture=f"accepted-{actor}")
            step("syncState", actor, capture=f"receipts-{actor}")
            step("receive", actor, capture=f"proposal-{actor}", bindings={"batch": f"batch-{peer}"}, error="mergeRecoveryRequired")
            step("receive", actor, bindings={"batch": f"batch-{peer}"}, error="mergeRecoveryRequired")
            step("save", actor, capture=f"still-accepted-{actor}")
            step("syncState", actor, capture=f"still-receipts-{actor}")
            equal(f"accepted-{actor}", f"still-accepted-{actor}")
            equal(f"receipts-{actor}", f"still-receipts-{actor}")
        equal("proposal-a", "proposal-b")
        step("close")
        step("restore", actorID="a", bindings={"snapshot": "accepted-a"})
        step("receive", bindings={"batch": ["proposal-a", "batch"]}, error="mergeRecoveryRequired")
        step("repairMerge", repairs=repairs[0])
        step("repairMerge", "b", repairs=repairs[1])
        for actor in ["a", "b"]:
            step("changes", actor, capture=f"repaired-{actor}")
        for actor, peer in [("b", "a"), ("a", "b")]:
            for _ in range(2):
                step("receive", actor, bindings={"batch": f"repaired-{peer}"})
            step("document", actor, capture=f"converged-{actor}", expected=both)
        # Local undo of the losing repair retains the other author's independent repair.
        step("undo", capture="undo-losing-repair", expected=both)
        step("changes", capture="undo-batch")
        step("receive", "b", bindings={"batch": "undo-batch"})
        step("document", "b", capture="remote-after-undo", expected=both)
        step("save", capture="saved-repaired")
        step("close")
        step("restore", actorID="a", bindings={"snapshot": "saved-repaired"}, capture="reopened", expected=both)
        step("redo", capture="redo-losing-repair", expected=both)
        step("changes", capture="redo-losing-batch")
        step("receive", "b", bindings={"batch": "redo-losing-batch"})
        earlier = [toggle("parent", [payloads[0]]), toggle("destination", [payloads[1]])] if kind == "collision" else both
        step("undo", "b", capture="undo-winning-repair", expected=earlier)
        step("changes", "b", capture="undo-winning-batch")
        step("receive", bindings={"batch": "undo-winning-batch"})
        step("document", capture="remote-after-winning-undo", expected=earlier)
        step("redo", "b", capture="redo-winning-repair", expected=both)
        step("changes", "b", capture="redo-winning-batch")
        step("receive", bindings={"batch": "redo-winning-batch"})
        step("document", capture="remote-after-winning-redo", expected=both)
        for actor in ["a", "b"]:
            step("close", actor)

# Exercise immediately below and above the actual required math-field limit.
for size in [9998, 9999]:
    key = f"recovery-generated-field-{size}"
    baseline_text = "x" * size
    blocks = [{"id": "math", "type": "math", "expression": baseline_text, "host": {"keep": True}}]
    def field_step(command, actor="a", capture=None, expected=None, bindings=None, error=None, **input):
        row = {"recoveryCampaign": key, "request": {"command": command, "session": f"{key}-{actor}", **copy.deepcopy(input)}}
        if capture:
            row["capture"] = f"{key}-{capture}"
            if expected is not None:
                fixture["expectedBlocks"][row["capture"]] = expected
        if bindings:
            row["bindings"] = {name: [f"{key}-{value[0]}", *value[1:]] if isinstance(value, list) else f"{key}-{value}" for name, value in bindings.items()}
        if error:
            row["error"] = error
        fixture["steps"].append(row)
    def field_expected(prefix):
        return [{**blocks[0], "expression": prefix + baseline_text}]
    for actor in ["a", "b"]:
        field_step("create", actor, documentID=key, actorID=actor, collaborationVersion=2, blocks=blocks)
        field_step("replaceText", actor, address={"blockID": "math", "path": ["expression"], "identity": baseline("math")}, start=0, end=0, text=actor.upper())
        field_step("document", actor, capture=f"accepted-document-{actor}", expected=field_expected(actor.upper()))
        field_step("changes", actor, capture=f"batch-{actor}")
        field_step("save", actor, capture=f"saved-{actor}")
        field_step("syncState", actor, capture=f"receipts-{actor}")
    # Same-clock siblings use descending stable atom identities: B precedes A.
    for actor, peer in [("a", "b"), ("b", "a")]:
        field_step("receive", actor, bindings={"batch": f"batch-{peer}"}, capture=f"proposal-{actor}" if size == 9999 else None,
                   error="mergeRecoveryRequired" if size == 9999 else None)
        field_step("document", actor, capture=f"after-receive-{actor}", expected=field_expected(actor.upper() if size == 9999 else "BA"))
    if size == 9999:
        fixture["equal"].append([f"{key}-proposal-a", f"{key}-proposal-b"])
        for actor in ["a", "b"]:
            for command, capture in [("save", "saved"), ("syncState", "receipts")]:
                field_step(command, actor, capture=f"still-{capture}-{actor}")
                fixture["equal"].append([f"{key}-{capture}-{actor}", f"{key}-still-{capture}-{actor}"])
        field_step("close")
        field_step("restore", actorID="a", bindings={"snapshot": "saved-a"})
        field_step("receive", bindings={"batch": ["proposal-a", "batch"]}, error="mergeRecoveryRequired", capture="restored-proposal")
        fixture["equal"].append([f"{key}-proposal-a", f"{key}-restored-proposal"])
    else:
        field_step("undo", capture="undo-a", expected=field_expected("B"))
        field_step("changes", capture="undo-batch")
        field_step("receive", "b", bindings={"batch": "undo-batch"})
        field_step("document", "b", capture="remote-after-undo", expected=field_expected("B"))
    for actor in ["a", "b"]:
        field_step("close", actor)

fixture["recoveryCampaign"] = {"version": 1, "collisionSeeds": seeds, "depthLevels": [17, 20, 22], "fieldBaselineLengths": [9998, 9999], "cases": 9}
# Keep original records readable; generated rows and oracles each occupy one line.
fields = []
for name, value in fixture.items():
    if name == "steps":
        rows = ["\n".join("    " + line for line in (json.dumps(row, ensure_ascii=False) if "recoveryCampaign" in row else json.dumps(row, indent=2)).splitlines()) for row in value]
        fields.append('  "steps": [\n' + ",\n".join(rows) + "\n  ]")
    elif name == "expectedBlocks":
        fields.append('  "expectedBlocks": {\n' + ",\n".join("    " + json.dumps(key) + ": " + json.dumps(blocks, ensure_ascii=False) for key, blocks in value.items()) + "\n  }")
    else:
        lines = json.dumps(value, indent=2).splitlines()
        fields.append("  " + json.dumps(name) + ": " + lines[0] + "".join("\n  " + line for line in lines[1:]))
result = "{\n" + ",\n".join(fields) + "\n}\n"
if "--check" in sys.argv:
    if path.read_text() != result:
        raise SystemExit("Recovery fixture is stale; run scripts/generate-recovery-history.py")
else:
    path.write_text(result)
