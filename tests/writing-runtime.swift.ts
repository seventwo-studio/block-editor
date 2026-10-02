import { test, expect } from "@playwright/test";

test("typed v4 splits pin committed prefix and preserve remote tail through reopened undo", async ({ page }) => {
  await page.route("**/writing-engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const results = await page.evaluate(async root => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("writing-engine.wasm")).arrayBuffer());
    const results = [];
    for (const list of [false, true]) for (const swap of [false, true]) {
      const content = [{ type: "text", text: "AB", marks: [{ type: "bold" }] }];
      const blocks = list ? [{ id: "p", type: "list", style: "todo", items: [{ id: "i", content, checked: true, host: "item" }] }]
        : [{ id: "p", type: "paragraph", content, host: "original" }];
      const actorID = swap ? "b" : "a", documentID = `typed-pin-${list}-${swap}`;
      const a = runtime.createWritingV4({ documentID, actorID, epoch: "pin-v4", blocks });
      const b = runtime.createWritingV4({ documentID, actorID: swap ? "a" : "b", epoch: "pin-v4", blocks });
      const field = { blockID: "p", path: list ? ["items", "i", "content"] : ["content"] };
      a.replaceText(field, 1, 1, "東京"); b.replaceText(field, 2, 2, "R"); a.receive(b.changes());
      const caret = list ? a.enterListItem(field, 3, 3, "tail") : a.splitParagraph(field, 3, 3, "tail");
      const resolved = a.resolvePosition(caret), split = a.getSnapshot().blocks;
      b.receive(a.changes()); const replica = b.getSnapshot().blocks;
      b.replaceText(resolved.address, 1, 1, "X"); a.receive(b.changes()); a.receive(b.changes());
      const reopened = runtime.restoreWriting(a.save(), actorID), accepted = reopened.getSnapshot().blocks;
      reopened.undo(); const undo = reopened.getSnapshot().blocks;
      reopened.redo(); const redo = reopened.getSnapshot().blocks;
      results.push({ list, offset: resolved.offset, split, replica, accepted, undo, redo });
      a.close(); b.close(); reopened.close();
    }
    return results;
  }, `/block-editor/@fs${process.cwd()}`);
  for (const result of results) {
    const nodes = (blocks: typeof result.split) => result.list ? blocks[0].items! : blocks;
    const texts = (blocks: typeof result.split) => nodes(blocks).map(node => node.content!.map(run => run.type === "text" ? run.text : "").join(""));
    expect(result.offset).toBe(0);
    expect(texts(result.split)).toEqual(["A東京", "BR"]);
    expect(result.replica).toEqual(result.split);
    expect(texts(result.accepted)).toEqual(["A東京", "BXR"]);
    expect(texts(result.undo)).toEqual(["A東京BXR"]);
    expect(result.redo).toEqual(result.accepted);
    for (const node of nodes(result.redo)) for (const run of node.content!) expect(run).toMatchObject({ marks: [{ type: "bold" }] });
  }
});

test("typed v4 middle exit keeps item identity and remote work through reopened undo", async ({ page }) => {
  await page.route("**/writing-engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const result = await page.evaluate(async root => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("writing-engine.wasm")).arrayBuffer());
    const blocks = [{ id: "list", type: "list", style: "todo", host: "root", items: [
      { id: "first", content: [{ type: "text", text: "before", marks: [] }] },
      { id: "empty", content: [], checked: true, host: "item" },
      { id: "last", content: [{ type: "text", text: "after", marks: [] }] },
    ] }];
    const a = runtime.createWritingV4({ documentID: "typed-exit", actorID: "a", epoch: "exit-v4", blocks });
    const b = runtime.createWritingV4({ documentID: "typed-exit", actorID: "b", epoch: "exit-v4", blocks });
    const owner = a.node({ blockID: "list", path: [] }), item = a.node({ blockID: "list", path: ["items", "empty"] });
    const field = { blockID: "list", path: ["items", "empty", "content"] };
    const caret = a.enterListItem(field, 0, 0, "tail");
    const exitIdentity = a.node({ blockID: "empty", path: [] }), remainingOwner = a.node({ blockID: "list", path: [] });
    const resolvedOffset = a.resolvePosition(caret).offset;
    b.replaceText(field, 0, 0, "peer");
    a.receive(b.changes()); b.receive(a.changes()); b.receive(a.changes());
    const accepted = a.getSnapshot().blocks, replica = b.getSnapshot().blocks;
    const reopened = runtime.restoreWriting(a.save(), "a");
    reopened.undo(); const undo = reopened.getSnapshot().blocks;
    const undoIdentity = reopened.node({ blockID: "list", path: ["items", "empty"] });
    reopened.redo(); const redo = reopened.getSnapshot().blocks;
    a.close(); b.close(); reopened.close();
    return { owner, item, exitIdentity, remainingOwner, resolvedOffset, accepted, replica, undo, undoIdentity, redo };
  }, `/block-editor/@fs${process.cwd()}`);
  expect(result.exitIdentity).toEqual(result.item);
  expect(result.remainingOwner).toEqual(result.owner);
  expect(result.undoIdentity).toEqual(result.item);
  expect(result.resolvedOffset).toBe(0);
  expect(result.accepted.map((block: { id: string }) => block.id)).toEqual(["list", "empty", "tail"]);
  expect(result.replica).toEqual(result.accepted);
  expect(result.undo[0].items[1]).toEqual({ id: "empty", content: [{ type: "text", text: "peer", marks: [] }], checked: true, host: "item" });
  expect(result.redo).toEqual(result.accepted);
});

test("typed v4 owner repair retains both historic head writes and rejected accepted state", async ({ page }) => {
  await page.route("**/writing-engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const result = await page.evaluate(async root => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("writing-engine.wasm")).arrayBuffer());
    const blocks = [
      { id: "left", type: "list", style: "todo", items: [{ id: "i", content: [{ type: "text", text: "keep😀", marks: [] }], host: "item" }] },
      { id: "right", type: "list", style: "ordered", items: [] },
    ];
    const a = runtime.createWritingV4({ documentID: "typed-owner", actorID: "a", epoch: "exit-v4", blocks });
    const b = runtime.createWritingV4({ documentID: "typed-owner", actorID: "b", epoch: "exit-v4", blocks });
    const item = b.node({ blockID: "left", path: ["items", "i"] });
    a.convertBlock({ blockID: "left", path: ["items", "i", "content"] }, 0, { type: "paragraph" });
    b.moveSelection({ nodes: [item], text: [] }, { owner: b.node({ blockID: "right", path: [] }), field: "items" });
    b.convertBlock({ blockID: "right", path: ["items", "i", "content"] }, 0, { type: "paragraph" });
    a.replaceText({ blockID: "left", path: ["content"] }, 0, 0, "A");
    b.replaceText({ blockID: "right", path: ["content"] }, 0, 0, "B");
    const aa = a.changes(), bb = b.changes(), before = JSON.stringify(a.save());
    const { SwiftWritingRecoveryError } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    let recoveryA: unknown, recoveryB: unknown;
    try { a.receive(bb); } catch (error) { if (!(error instanceof SwiftWritingRecoveryError)) throw error; recoveryA = error.recovery; }
    try { b.receive(aa); } catch (error) { if (!(error instanceof SwiftWritingRecoveryError)) throw error; recoveryB = error.recovery; }
    const rejectedA = recoveryA !== undefined && JSON.stringify(recoveryA) === JSON.stringify(a.mergeRecovery());
    const rejectedB = recoveryB !== undefined && JSON.stringify(recoveryB) === JSON.stringify(b.mergeRecovery());
    const preserved = JSON.stringify(a.save()) === before;
    a.repairUndo({ counter: 1, actor: "a" }); b.receive(a.changes());
    const repaired = a.getSnapshot().blocks, replica = b.getSnapshot().blocks;
    const reopened = runtime.restoreWriting(a.save(), "a"), restored = reopened.getSnapshot().blocks;
    a.close(); b.close(); reopened.close();
    return { rejectedA, rejectedB, recoveryA, recoveryB, preserved, repaired, replica, restored };
  }, `/block-editor/@fs${process.cwd()}`);
  expect(result.rejectedA && result.rejectedB && result.preserved).toBe(true);
  expect(result.recoveryA).toMatchObject({ reason: "schemaConstraint", batch: { version: 4, epoch: "exit-v4" } });
  expect(result.recoveryB).toMatchObject({ reason: "schemaConstraint", batch: { version: 4, epoch: "exit-v4" } });
  expect(result.repaired[1].content).toEqual([{ type: "text", text: "BAkeep😀", marks: [] }]);
  expect(result.replica).toEqual(result.repaired);
  expect(result.restored).toEqual(result.repaired);
});

test("typed v4 collection commands keep scoped IDs and remote work across author undo", async ({ page }) => {
  await page.route("**/writing-engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const result = await page.evaluate(async root => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("writing-engine.wasm")).arrayBuffer());
    const blocks = [{ id: "table", type: "table", rows: [], columnWidths: [120], extension: "keep" }];
    const a = runtime.createWritingV4({ documentID: "typed-collections", actorID: "a", epoch: "collections-v4", blocks });
    const b = runtime.createWritingV4({ documentID: "typed-collections", actorID: "b", epoch: "collections-v4", blocks });
    const rows = { owner: a.node({ blockID: "table", path: [] }), field: "rows" };
    const values = ["one", "two"].map(id => ({ id, cells: [{ id: "same", content: [{ type: "text", text: id, marks: [] }], extension: { id: "consumer" } }] }));
    const created = a.insertCollectionNodes(values, rows);
    const initialIdentities = a.collectionNodes(rows);
    b.receive(a.changes());
    b.replaceText({ blockID: "table", path: ["rows", "one", "cells", "same", "content"] }, 0, 0, "R");
    a.receive(b.changes());
    a.moveSelection({ nodes: [created.nodes[0]], text: [] }, rows, created.nodes[1]);
    const reordered = a.getSnapshot().blocks;
    const reopened = runtime.restoreWriting(a.save(), "a");
    reopened.undo(); const moveUndo = reopened.getSnapshot().blocks;
    reopened.undo(); const creationUndo = reopened.getSnapshot().blocks;
    reopened.redo(); const redo = reopened.getSnapshot().blocks;
    const restoredIdentities = reopened.collectionNodes(rows);
    a.close(); b.close(); reopened.close();
    return { created: created.nodes, initialIdentities, reordered, moveUndo, creationUndo, redo, restoredIdentities };
  }, `/block-editor/@fs${process.cwd()}`);
  expect(result.initialIdentities).toEqual(result.created);
  expect(result.restoredIdentities).toEqual(result.created);
  expect(result.reordered[0].rows.map((row: { id: string }) => row.id)).toEqual(["two", "one"]);
  expect(result.moveUndo[0].rows[0].cells[0]).toEqual({ id: "same", content: [{ type: "text", text: "Rone", marks: [] }], extension: { id: "consumer" } });
  expect(result.creationUndo).toEqual([{ id: "table", type: "table", rows: [{ id: "one", cells: [{ id: "same", content: [{ type: "text", text: "R", marks: [] }], extension: { id: "consumer" } }] }], columnWidths: [120], extension: "keep" }]);
  expect(result.redo).toEqual(result.moveUndo);
});

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
