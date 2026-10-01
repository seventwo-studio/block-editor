import { test, expect } from "@playwright/test";

test("typed v3 writing commands and composition queues preserve accepted history", async ({ page }) => {
  await page.route("**/writing-engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const result = await page.evaluate(async root => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("writing-engine.wasm")).arrayBuffer());
    const blocks = [{ id: "left", type: "paragraph", content: [{ type: "text", text: "abcd", marks: [] }] }];
    const a = runtime.createWriting({ documentID: "typed", actorID: "a", epoch: "v3", blocks });
    const b = runtime.createWriting({ documentID: "typed", actorID: "b", epoch: "v3", blocks });
    const position = a.splitParagraph({ blockID: "left", path: ["content"] }, 2, 2, "right");
    b.replaceText({ blockID: "left", path: ["content"] }, 3, 3, "X");
    b.format({ blockID: "left", path: ["content"] }, 2, 3, "bold", { type: "bold" });
    const left = a.changes(), right = b.changes(); a.receive(right); b.receive(left);
    const converged = JSON.stringify(a.getSnapshot()) === JSON.stringify(b.getSnapshot());
    const splitBlocks = a.getSnapshot().blocks, resolved = a.resolvePosition(position);
    const reopened = runtime.restoreWriting(a.save(), "a"); reopened.undo();
    const undoBlocks = reopened.getSnapshot().blocks;

    const seed = [{ id: "left", type: "paragraph", content: [{ type: "text", text: "ab", marks: [] }] }];
    const c = runtime.createWriting({ documentID: "composition", actorID: "c", epoch: "v3", blocks: seed });
    const d = runtime.createWriting({ documentID: "composition", actorID: "d", epoch: "v3", blocks: seed });
    const e = runtime.createWriting({ documentID: "composition", actorID: "e", epoch: "v3", blocks: seed });
    d.replaceText({ blockID: "left", path: ["content"] }, 1, 1, "X");
    e.replaceText({ blockID: "left", path: ["content"] }, 2, 2, "Z");
    const accepted = JSON.stringify(c.save()), release = c.deferRemoteChanges();
    c.receive(d.changes());
    const held = accepted === JSON.stringify(c.save()) && c.syncState().received.length === 0;
    let nextRelease: (() => void) | undefined;
    c.subscribe(() => { if (!nextRelease) { nextRelease = c.deferRemoteChanges(); c.receive(e.changes()); } });
    release(); const queued = c.exportDeferredChanges().length;
    nextRelease?.(); const composedBlocks = c.getSnapshot().blocks;
    c.setComposing(true); let compositionGuard = false;
    try { c.splitParagraph({ blockID: "left", path: ["content"] }, 1, 1, "blocked"); }
    catch (error) { compositionGuard = error instanceof Error && error.message === "compositionActive"; }
    c.setComposing(false);

    const badRelease = c.deferRemoteChanges(); c.receive({ ...d.changes(), epoch: "wrong" });
    let protocolError = false;
    try { badRelease(); } catch (error) { protocolError = error instanceof Error && error.message === "incompatibleEpoch"; }
    const retained = c.exportDeferredChanges();
    let closeGuard = false; try { c.close(); } catch { closeGuard = true; }
    c.close({ pendingStateRetained: retained.length === 1 });
    a.close(); b.close(); reopened.close(); d.close(); e.close();
    return { converged, splitBlocks, resolvedOffset: resolved.offset, undoBlocks, held, queued, composedBlocks, compositionGuard, protocolError, closeGuard, retainedEpoch: retained[0].epoch };
  }, `/block-editor/@fs${process.cwd()}`);
  expect(result.converged).toBe(true);
  expect(result.splitBlocks).toEqual([
    { id: "left", type: "paragraph", content: [{ type: "text", text: "ab", marks: [] }] },
    { id: "right", type: "paragraph", content: [{ type: "text", text: "c", marks: [{ type: "bold" }] }, { type: "text", text: "Xd", marks: [] }] },
  ]);
  expect(result.resolvedOffset).toBe(0);
  expect(result.undoBlocks).toEqual([{ id: "left", type: "paragraph", content: [{ type: "text", text: "ab", marks: [] }, { type: "text", text: "c", marks: [{ type: "bold" }] }, { type: "text", text: "Xd", marks: [] }] }]);
  expect(result.held).toBe(true); expect(result.queued).toBe(1);
  expect(result.composedBlocks).toEqual([{ id: "left", type: "paragraph", content: [{ type: "text", text: "aXbZ", marks: [] }] }]);
  expect(result.compositionGuard).toBe(true); expect(result.protocolError).toBe(true);
  expect(result.closeGuard).toBe(true); expect(result.retainedEpoch).toBe("wrong");
});

test("typed batch ranges retain remote text, identities and one reopened undo", async ({ page }) => {
  await page.route("**/writing-engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const result = await page.evaluate(async root => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("writing-engine.wasm")).arrayBuffer());
    const blocks = ["first", "middle", "last"].map((id, index) => ({ id, type: "paragraph" as const,
      content: [{ type: "text" as const, text: ["ABC", "kept", "XYZ"][index], marks: [] }] }));
    const a = runtime.createWriting({ documentID: "batch", actorID: "a", epoch: "v3", blocks });
    const b = runtime.createWriting({ documentID: "batch", actorID: "b", epoch: "v3", blocks });
    const selected = a.selection(a.position({ blockID: "last", path: ["content"] }, 2), a.position({ blockID: "first", path: ["content"] }, 1));
    const copied = a.copySelection(selected);
    b.replaceText({ blockID: "first", path: ["content"] }, 0, 0, "R-");
    b.replaceText({ blockID: "last", path: ["content"] }, 3, 3, "!");
    a.receive(b.changes());
    const caret = a.deleteSelection(selected), deleted = a.getSnapshot().blocks;
    const offsets = caret.text.map(span => a.resolvePosition(span.start).offset);
    const reopened = runtime.restoreWriting(a.save(), "a"); reopened.undo();
    const undone = reopened.getSnapshot();
    const first = reopened.node({ blockID: "first", path: [] });
    const last = reopened.node({ blockID: "last", path: [] });
    const moved = reopened.moveSelection({ nodes: [first], text: [] }, { field: "blocks" }, last);
    const copy = reopened.duplicateSelection(moved, { field: "blocks" }, first);
    const duplicateText = reopened.copySelection(copy).nodes[0];
    const fresh = JSON.stringify(first) !== JSON.stringify(copy.nodes[0]);
    const order = reopened.getSnapshot().blocks.map(block => block.id);
    a.close(); b.close(); reopened.close();
    return { copied, deleted, offsets, undone, duplicateText, fresh, order };
  }, `/block-editor/@fs${process.cwd()}`);
  expect(result.copied.text.map(parts => parts.map(node => "text" in node ? node.text : "").join(""))).toEqual(["BC", "XY"]);
  expect(result.copied.nodes).toEqual([{ id: "middle", type: "paragraph", content: [{ type: "text", text: "kept", marks: [] }] }]);
  expect(result.deleted).toEqual([
    { id: "first", type: "paragraph", content: [{ type: "text", text: "R-A", marks: [] }] },
    { id: "last", type: "paragraph", content: [{ type: "text", text: "Z!", marks: [] }] },
  ]);
  expect(result.offsets).toEqual([3, 0]);
  expect(result.undone.canUndo).toBe(false); expect(result.undone.canRedo).toBe(true);
  expect(result.undone.blocks.map(block => block.content?.map(node => "text" in node ? node.text : "").join(""))).toEqual(["R-ABC", "kept", "XYZ!"]);
  expect(result.fresh).toBe(true);
  expect(result.order.slice(0, 3)).toEqual(["middle", "last", "first"]);
  expect(result.duplicateText).toMatchObject({ type: "paragraph", content: [{ type: "text", text: "R-ABC", marks: [] }] });
});
