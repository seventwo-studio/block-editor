#!/usr/bin/env python3
"""Check fixture contract integrity only; never execute or accept editor semantics."""
import argparse
import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
HOSTS = {"macOS", "iPhone", "iPad", "Android", "visionOS", "watchOS", "tvOS", "ReactWASM"}
OWNERS = {f"ST-{value}" for value in range(122, 144)} | {"ST-104"}
PALETTE = {"neutral", "green", "blue", "purple", "amber", "red"}
LAYERS = {"sharedSemantics", "hostInteraction", "rendering", "assistive", "physicalInput", "physicalPerformance"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key {key}")
        result[key] = value
    return result


def read(path):
    return json.loads(path.read_text(), object_pairs_hook=unique_object,
                      parse_constant=lambda value: require(False, f"nonfinite JSON {value}"))


def document_path(relative):
    path = (ROOT / relative).resolve()
    require(path.is_relative_to(ROOT / "documents") and path.suffix == ".json" and path.is_file(),
            f"missing/outside document {relative}")
    return path


def siblings(values, label):
    ids = [item.get("id") for item in values]
    require(all(isinstance(value, str) and value for value in ids), f"empty identity {label}")
    require(len(set(ids)) == len(ids), f"duplicate sibling identity {label}")


def inspect_inline(values):
    require(isinstance(values, list), "inline field must be an array")
    for item in values:
        require(isinstance(item, dict), "inline node must be an object")
        kind = item.get("type")
        if kind == "text":
            require(isinstance(item.get("text"), str), "text node needs literal text")
            for mark in item.get("marks", []):
                require(mark.get("type") in {"bold", "italic", "strikethrough", "code", "link",
                                             "semantic-color", "semantic-background"}, "unknown modern mark")
                if mark["type"].startswith("semantic-"):
                    require(mark.get("value") in PALETTE, "invalid palette role")
        elif kind in {"entity-ref", "mention"}:
            require(all(isinstance(item.get(key), str) for key in ["entityId", "entityType", "label"]),
                    "reference requires original entityId/entityType/label")
        else:
            require(kind in {"date", "emoji", "inline-math"}, "unknown inline representation")


def inspect_document(document):
    require(isinstance(document.get("blocks"), list), "document needs blocks")
    siblings(document["blocks"], "root")
    if "format" not in document:
        return  # Original legacy inputs include deliberate unadmittable content; preserve it verbatim.
    require(document["format"] == "seventwo.block-editor.document" and
            type(document.get("formatVersion")) is int and document["formatVersion"] == 1, "format mismatch")
    require(isinstance(document.get("documentID"), str) and document["documentID"], "missing document identity")
    require(isinstance(document.get("title"), str) and not any(c in document["title"] for c in "\r\n"),
            "accepted title must be plain, single-line text")
    appearance = document.get("appearance", {})
    require(appearance.get("fontFamily") in {"sans", "serif", "monospace"} and
            appearance.get("fontSize") in {"small", "default", "large"} and
            appearance.get("pageWidth") in {"readable", "wide"}, "invalid appearance preset")

    def walk_blocks(blocks, under_columns=False):
        siblings(blocks, "block collection")
        for block in blocks:
            kind = block.get("type")
            for key in ["semanticColor", "semanticBackground"]:
                if key in block:
                    require(block[key] in PALETTE, "invalid block palette role")
            if kind == "columns":
                require(not under_columns, "nested layout in accepted snapshot")
                columns = block.get("columns", [])
                require(len(columns) == 2, "accepted layout must have exactly two containers")
                siblings(columns, "column containers")
                split = block.get("splitBasisPoints")
                require(type(split) is int and 1000 <= split <= 9000, "invalid shared split")
                for column in columns:
                    walk_blocks(column["children"], True)
            elif kind == "toggle":
                inspect_inline(block.get("summary", []))
                walk_blocks(block.get("children", []), under_columns)
            elif kind == "list":
                def walk_items(items):
                    siblings(items, "list items")
                    for item in items:
                        inspect_inline(item.get("content", []))
                        walk_items(item.get("children", []))
                walk_items(block.get("items", []))
            elif kind == "table":
                siblings(block.get("rows", []), "table rows")
                for row in block.get("rows", []):
                    siblings(row.get("cells", []), "row cells")
                    for cell in row.get("cells", []):
                        inspect_inline(cell.get("content", []))
            elif kind in {"paragraph", "heading", "quote", "callout"}:
                inspect_inline(block.get("content", []))
            elif kind == "image":
                inspect_inline(block.get("caption", []))
            elif kind == "code":
                require(isinstance(block.get("code"), str), "literal code required")
            # Unknown block payload/consumer IDs are deliberately not schema identity collections.
    walk_blocks(document["blocks"])


def descendants(node):
    for key in ["blocks", "columns", "children", "items", "rows", "cells"]:
        for child in node.get(key, []):
            yield child
            yield from descendants(child)


def origin_node(document, origin, scenario, label):
    if origin == "$document":
        require("title" in document, "title origin in legacy input")
        return document
    binding = scenario.get("originBindings", {}).get(origin)
    path = binding.get("checkpointPaths", {}).get(label, binding["initialPath"]) if binding else origin
    parts = path.split("/")
    matches = [node for node in descendants(document) if node.get("id") == parts[0]]
    require(len(matches) == 1, f"ambiguous/deleted origin {origin} at {label}")
    node = matches[0]
    for part in parts[1:]:
        children = [child for key in ["columns", "children", "items", "rows", "cells"]
                    for child in node.get(key, []) if child.get("id") == part]
        require(len(children) == 1, f"missing/ambiguous scoped origin {origin} at {label}")
        node = children[0]
    return node


def plain(value):
    if isinstance(value, str):
        return value
    require(isinstance(value, list), "selected field is not text")
    return "".join(item.get("text", item.get("label", "")) for item in value)


def inspect_position(state, document, scenario, label):
    kind = state.get("kind")
    require(kind in {"none", "caret", "textRange", "nodes", "bodyInsertion", "readOnly", "control", "input"},
            "unspecified selection/focus kind")
    if kind == "nodes":
        require(len(state["origins"]) == len(set(state["origins"])), "duplicate node selection")
        for origin in state["origins"]:
            origin_node(document, origin, scenario, label)
    elif kind in {"caret", "textRange", "input"}:
        node = origin_node(document, state["origin"], scenario, label)
        require(state["field"] in node, f"missing text field {state['origin']}:{state['field']}")
        text = plain(node[state["field"]])
        boundaries = {0}
        offset = 0
        for scalar in text:
            offset += len(scalar.encode("utf-16-le")) // 2
            boundaries.add(offset)
        for key in ["offsetUTF16", "startUTF16", "endUTF16"]:
            if key in state:
                require(type(state[key]) is int and state[key] in boundaries,
                        f"invalid scalar boundary {state['origin']}:{key}={state[key]}")


def inspect_state(state, scenario, label):
    document = read(document_path(state["document"]))
    inspect_position(state["selection"], document, scenario, label)
    inspect_position(state["focus"], document, scenario, label)
    if "savedTextCaret" in state:
        inspect_position(state["savedTextCaret"], document, scenario, label)
    for key in ["availableUndoGroups", "availableRedoGroups"]:
        require(type(state["history"][key]) is int and state["history"][key] >= 0, "invalid history count")


def verify():
    catalog = read(ROOT / "fixtures.json")
    matrix = read(ROOT / "scenarios.json")
    host_matrix = read(ROOT / "hosts.json")
    require(set(host_matrix["hosts"]) == HOSTS, "host scope drift")
    for fixture in catalog["fixtures"].values():
        document = read(document_path(fixture["path"]))
        if "documentID" in document:
            require(fixture["documentID"] == document["documentID"], "fixture identity mismatch")
        require(fixture["epoch"] and fixture["qualification"], "missing fixture boundary")
    ids = set()
    checkpoints = 0
    for scenario in matrix["scenarios"]:
        require(scenario["id"] not in ids, "duplicate scenario identity")
        ids.add(scenario["id"])
        require(scenario["fixture"] in catalog["fixtures"], "missing initial fixture")
        require(scenario["owner"] in OWNERS, "unknown owning issue")
        require(set(scenario["hosts"]) <= HOSTS and scenario["hosts"], "scenario host scope drift")
        require(set(scenario["requiredEvidence"]) <= LAYERS, "unknown evidence kind")
        require(scenario["runtimeStatus"] == "pending", "fixture contract cannot accept runtime")
        require(scenario["actions"] and scenario["commands"] and scenario["expectedCheckpoints"], "empty scenario")
        require(scenario["initialState"]["document"] == catalog["fixtures"][scenario["fixture"]]["path"],
                "initial snapshot mismatch")
        inspect_state(scenario["initialState"], scenario, "initial")
        for checkpoint in scenario["expectedCheckpoints"]:
            require(checkpoint["status"] in {"applied", "noop", "unavailable", "recoveryRequired"}, "unknown result")
            inspect_state(checkpoint, scenario, checkpoint["label"])
            checkpoints += 1
    documents = sorted((ROOT / "documents").glob("*.json"))
    for path in documents:
        inspect_document(read(path))
    return {"qualification": "Fixture contract integrity only; zero modern runtime acceptance claims",
            "fixtureCatalogCount": len(catalog["fixtures"]), "scenarioCount": len(ids),
            "fullDocumentCount": len(documents), "expectedCheckpointCount": checkpoints,
            "runtimeScenariosPending": len(ids), "committedHostCount": len(HOSTS)}


def self_test():
    document = read(ROOT / "documents/columns-3000.json")
    corrupted = copy.deepcopy(document)
    corrupted["blocks"][0]["columns"].append({"id": "third", "children": []})
    duplicate = copy.deepcopy(document)
    duplicate["blocks"][0]["columns"][0]["children"].append(copy.deepcopy(duplicate["blocks"][0]["columns"][0]["children"][0]))
    bad_split = copy.deepcopy(document)
    bad_split["blocks"][0]["splitBasisPoints"] = 999
    injections = [lambda: inspect_document(corrupted), lambda: inspect_document(duplicate),
                  lambda: inspect_document(bad_split), lambda: document_path("../missing.json"),
                  lambda: inspect_position({"kind": "caret", "origin": "unicode", "field": "content", "offsetUTF16": 4},
                                           read(ROOT / "documents/unicode.json"), {}, "initial"),
                  lambda: origin_node(document, "deleted-origin", {}, "initial")]
    for inject in injections:
        try:
            inject()
        except ValueError:
            continue
        raise ValueError("corrupt contract escaped readiness validation")
    return len(injections)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    result = verify()
    if args.self_test:
        result["rejectedCorruptionChecks"] = self_test()
    if args.receipt:
        paths = (sorted(ROOT.glob("*.json")) + sorted((ROOT / "documents").glob("*.json")) +
                 sorted(ROOT.glob("*.py")) + sorted(ROOT.glob("*.md")))
        result["sha256"] = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in paths if path.resolve() != args.receipt.resolve()}
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "sha256"}, indent=2))
