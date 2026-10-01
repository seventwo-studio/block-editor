#!/usr/bin/env python3
"""Reproduce why copy/delete is not a collaborative split/merge implementation.

Default succeeds when the known counterexamples reproduce. --expect-correct is a
failing acceptance probe for the proposed shortcuts, never the current engine's
advertised contract. No shared split/merge command exists yet.
"""
import argparse
import json
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("bridge")
parser.add_argument("--expect-correct", action="store_true")
args = parser.parse_args()


def text(value, marks=None):
    return {"type": "text", "text": value, "marks": marks or []}


def paragraph(label, value):
    return {"id": label, "type": "paragraph", "content": [text(value)]}


def origin(label):
    return {"baseline": {"blockID": label, "path": []}}


def address(label):
    return {"blockID": label, "path": ["content"], "identity": origin(label)}


def witness(kind):
    process = subprocess.Popen([args.bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    def call(command, actor="a", **fields):
        process.stdin.write(json.dumps({"command": command, "session": actor, **fields}) + "\n")
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        if not response["ok"]:
            raise RuntimeError(response)
        return response["value"]
    try:
        blocks = [paragraph("p", "abcd")] if kind != "merge" else [paragraph("left", "ab"), paragraph("right", "cd")]
        for actor in ["a", "b"]:
            call("create", actor, documentID=kind, actorID=actor, blocks=blocks, collaborationVersion=2)
        if kind != "merge":
            # The renderer copies the suffix into a new paragraph then deletes it
            # from the original field. These are separate author transactions.
            call("setText", address=address("p"), text="ab")
            call("insertNode", value=paragraph("right", "cd"), collection={"field": "blocks"}, after=origin("p"))
            if kind == "split-text":
                call("replaceText", "b", address=address("p"), start=3, end=3, text="X")
                desired = [paragraph("p", "ab"), paragraph("right", "cXd")]
            else:
                call("format", "b", address=address("p"), start=2, end=3, markType="bold", mark={"type": "bold"})
                desired = [paragraph("p", "ab"), {"id": "right", "type": "paragraph", "content": [text("c", [{"type": "bold"}]), text("d")]}]
        else:
            call("setText", address=address("left"), text="abcd")
            call("deleteNode", identity=origin("right"))
            call("replaceText", "b", address=address("right"), start=2, end=2, text="X")
            desired = [paragraph("left", "abcdX")]
        call("receive", batch=call("changes", "b"))
        call("receive", "b", batch=call("changes"))
        actual = call("document")["blocks"]
        assert call("document", "b")["blocks"] == actual, "Replicas themselves diverged"
        assert actual != desired, "Counterexample changed; investigate the new behavior"
        call("undo")
        after_undo = call("document")["blocks"]
        return {"case": kind, "replicasConverged": True, "actual": actual, "desired": desired, "oneUndoActual": after_undo}
    finally:
        process.stdin.close()
        process.wait()


cases = [witness(kind) for kind in ["split-text", "split-format", "merge"]]
print(json.dumps(cases, indent=2))
if args.expect_correct:
    raise SystemExit("ST-97: copy/delete shortcuts converge but fail all three content/mark expectations")
