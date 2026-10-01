#!/usr/bin/env python3
"""Append reproducible collection histories with document oracles, without calling the engine."""
import copy
import json
from pathlib import Path
import sys

path = Path(__file__).resolve().parents[1] / "tests/BlockEditorCoreTests/Fixtures/structure.json"
fixture = json.loads(path.read_text())
fixture["steps"] = [step for step in fixture["steps"] if "campaign" not in step]
fixture["expectedBlocks"] = {}
seeds = [1, 7, 42, 255, 65537, 20260930, 999983, 4294967295]
kinds = ["root", "toggleChildren", "listItems", "tableRows", "tableCells"]


def text(value, marks=None):
    return {"type": "text", "text": value, "marks": marks or []}


def payload(kind, label):
    host = {"preserve": True, "origin": label, "opaque": [7, {"id": "extension-id", "text": "é"}]}
    content = [text("café 👩🏽‍💻 é 日本語 ", [{"type": "italic"}]),
               {"type": "entity-ref", "entityId": f"entity-{label}", "entityType": "note", "label": "Ref", "host": host}]
    leaf = {"id": f"leaf-{label}", "content": copy.deepcopy(content), "host": host}
    if kind == "root":
        return {"id": label, "type": "toggle", "summary": content, "children": [{**leaf, "type": "paragraph"}], "host": host}
    if kind == "toggleChildren":
        return {"id": label, "type": "paragraph", "content": content, "host": host}
    if kind == "listItems":
        return {"id": label, "content": content, "checked": True, "children": [leaf], "host": host}
    if kind == "tableRows":
        return {"id": label, "cells": [{**leaf, "header": True}], "host": host}
    return {"id": label, "content": content, "header": True, "host": host}


for kind in kinds:
    for seed in seeds:
        key = f"collection-{kind}-{seed}"
        field = {"root": "blocks", "toggleChildren": "children", "listItems": "items", "tableRows": "rows", "tableCells": "cells"}[kind]
        if kind == "root":
            blocks = [payload(kind, f"member-{i}") for i in range(6)]
            arrays = [blocks]
            owners = [None]
        else:
            blocks, arrays, owners = [], [], []
            for i in range(3):
                members = [payload(kind, f"member-{i}-{j}") for j in range(2)]
                block = {"id": f"container-{i}", "host": {"keep": True}}
                if kind == "toggleChildren":
                    block.update(type="toggle", summary=[text("container")], children=members)
                elif kind == "listItems":
                    block.update(type="list", style="todo", items=members)
                elif kind == "tableRows":
                    block.update(type="table", rows=members)
                else:
                    block.update(type="table", rows=[{"id": "row", "cells": members, "host": {"keep": True}}])
                blocks.append(block)
                arrays.append(members)
                owners.append({"baseline": {"blockID": block["id"], "path": ["rows", "row"] if kind == "tableCells" else []}})
        source = seed % len(arrays)
        member_index = (seed // 3) % len(arrays[source])
        member = arrays[source][member_index]
        owner = owners[source]
        origin = {"blockID": member["id"], "path": []} if owner is None else {
            "blockID": owner["baseline"]["blockID"], "path": owner["baseline"]["path"] + [field, member["id"]]}
        identity = {"baseline": origin}
        text_origin = copy.deepcopy(origin)
        if kind == "tableRows":
            text_origin["path"] += ["cells", member["cells"][0]["id"]]
        address = {**text_origin, "path": text_origin["path"] + ["summary" if kind == "root" else "content"],
                   "identity": {"baseline": text_origin}}
        target_a, target_b = (source + 1) % len(arrays), (source + 2) % len(arrays)

        def collection(index):
            return {"field": field, **({"owner": owners[index]} if owners[index] is not None else {})}

        def anchor(index, last):
            siblings = [value for value in arrays[index] if value["id"] != member["id"]]
            sibling = siblings[-1 if last else 0]
            return {"baseline": {"blockID": sibling["id"], "path": []}} if owners[index] is None else {
                "baseline": {"blockID": owners[index]["baseline"]["blockID"],
                             "path": owners[index]["baseline"]["path"] + [field, sibling["id"]]}}

        # Independent expected document after local undo: only B's move/text/mark remain.
        remote = copy.deepcopy(blocks)
        remote_arrays = [remote] if kind == "root" else [
            block["rows"][0]["cells"] if kind == "tableCells" else block[field] for block in remote]
        moved = remote_arrays[source].pop(member_index)
        inline_owner = moved["cells"][0] if kind == "tableRows" else moved
        inline_field = "summary" if kind == "root" else "content"
        inline_owner[inline_field].insert(0, text("B", [{"type": "bold"}]))
        remote_arrays[target_b].append(moved)
        both = copy.deepcopy(remote)
        both_array = both if kind == "root" else (both[target_b]["rows"][0]["cells"] if kind == "tableCells" else both[target_b][field])
        both_owner = both_array[-1]["cells"][0] if kind == "tableRows" else both_array[-1]
        both_owner[inline_field].insert(0, text("A"))

        def step(command, author="a", capture=None, expected=None, bindings=None, **values):
            row = {"campaign": key, "request": {"command": command, "session": f"{key}-{author}", **copy.deepcopy(values)}}
            if capture:
                row["capture"] = f"{key}-{capture}"
                if expected is not None:
                    fixture["expectedBlocks"][row["capture"]] = copy.deepcopy(expected)
            if bindings:
                row["bindings"] = {name: f"{key}-{value}" for name, value in bindings.items()}
            fixture["steps"].append(row)

        for author in ["a", "b"]:
            step("create", author, documentID=key, actorID=author, blocks=blocks, collaborationVersion=2)
        step("moveNode", identity=identity, collection=collection(target_a), after=anchor(target_a, False))
        step("replaceText", address=address, start=0, end=0, text="A", marks=[])
        step("replaceText", "b", address=address, start=0, end=0, text="B", marks=[])
        step("format", "b", address=address, start=0, end=1, markType="bold", mark={"type": "bold"})
        step("moveNode", "b", identity=identity, collection=collection(target_b), after=anchor(target_b, True))
        step("save", capture="offlineSave")
        step("close")
        step("restore", actorID="a", bindings={"snapshot": "offlineSave"})
        for author in ["a", "b"]:
            step("changes", author, capture=f"changes-{author}")
        for author, other in [("a", "b"), ("b", "a")]:
            for _ in range(2):
                step("receive", author, bindings={"batch": f"changes-{other}"})
        step("document", capture="bothAuthors", expected=both)
        step("undo", capture="afterLocalTextUndo", expected=remote)
        step("undo", capture="afterLocalMoveUndo", expected=remote)
        step("changes", capture="localUndo")
        step("receive", "b", bindings={"batch": "localUndo"})
        step("receive", "b", bindings={"batch": "localUndo"})
        step("document", "b", capture="remoteAfterLocalUndo", expected=remote)
        for _ in range(2):
            step("redo")
        step("changes", capture="localRedo")
        step("receive", "b", bindings={"batch": "localRedo"})
        step("document", capture="bothAuthorsAfterRedo", expected=both)
        for _ in range(2):
            step("undo")
        step("changes", capture="localUndoAgain")
        step("receive", "b", bindings={"batch": "localUndoAgain"})
        for _ in range(3):
            step("undo", "b")
        step("changes", "b", capture="remoteUndo")
        step("receive", bindings={"batch": "remoteUndo"})
        for author in ["a", "b"]:
            step("document", author, capture=f"baseline-{author}", expected=blocks)
        step("save", capture="finalSave")
        step("close")
        step("restore", actorID="a", capture="restoredBaseline", expected=blocks, bindings={"snapshot": "finalSave"})
        for author in ["a", "b"]:
            step("close", author)

fixture["collectionCampaign"] = {"version": 1, "seeds": seeds, "kinds": kinds, "cases": len(seeds) * len(kinds)}
# Keep existing hand-authored steps readable; generated rows are one JSON record
# per line, with their generator and case labels providing the reviewable source.
fields = []
for name, value in fixture.items():
    if name == "steps":
        rows = []
        for row in value:
            rendered = json.dumps(row, ensure_ascii=False) if "campaign" in row else json.dumps(row, indent=2)
            rows.append("\n".join("    " + line for line in rendered.splitlines()))
        fields.append('  "steps": [\n' + ",\n".join(rows) + "\n  ]")
    elif name == "expectedBlocks":
        rows = ["    " + json.dumps(key) + ": " + json.dumps(blocks, ensure_ascii=False) for key, blocks in value.items()]
        fields.append('  "expectedBlocks": {\n' + ",\n".join(rows) + "\n  }")
    else:
        rendered = json.dumps(value, indent=2).splitlines()
        fields.append("  " + json.dumps(name) + ": " + rendered[0] + "".join("\n  " + line for line in rendered[1:]))
result = "{\n" + ",\n".join(fields) + "\n}\n"
if "--check" in sys.argv:
    if path.read_text() != result:
        raise SystemExit("Collection fixture is stale; run scripts/generate-collection-history.py")
else:
    path.write_text(result)
