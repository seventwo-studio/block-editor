import { test, expect } from "@playwright/test";

test("typed writing math thresholds preserve accepted state, peer atoms and recoverable author history", async ({ page }) => {
  test.setTimeout(180_000);
  await page.route("**/writing-engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const samples = await page.evaluate(async root => {
    const { SwiftEditorRuntime, SwiftWritingRecoveryError } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("writing-engine.wasm")).arrayBuffer());
    const rich = { id: "rich", type: "paragraph", host: "retained", content: [
      { type: "text", text: "café 東京😀", marks: [{ type: "bold" }] },
      { type: "entity-ref", entityType: "task", entityId: "outside", label: "Task", consumer: { id: "reference-opaque" } },
    ] };
    const samples = [];
    const pending = (operation: () => unknown) => {
      try { operation(); } catch (error) { if (error instanceof SwiftWritingRecoveryError) return error.recovery; throw error; }
      throw new Error("Over-limit union must retain a proposal");
    };
    for (const version of [4, 5]) for (const actorID of ["a", "z"]) for (const length of [9_998, 9_999]) {
      const math = { id: "math", type: "math", expression: "x".repeat(length), consumer: { id: "math-opaque", children: [{ id: "opaque-child" }] } };
      const create = (writer: string) => {
        const options = { documentID: `typed-threshold-${version}`, actorID: writer, epoch: `threshold-${version}`, blocks: [math, rich] };
        return version === 4 ? runtime.createWritingV4(options) : runtime.createWritingV5(options);
      };
      const a = create(actorID), b = create("m"), address = { blockID: "math", path: ["expression"] };
      const positionA = a.replaceText(address, length, length, "A"), positionB = b.replaceText(address, length, length, "B");
      const own = a.changes(), remote = b.changes(), suffix = actorID === "z" ? "AB" : "BA";
      if (length === 9_998) {
        a.receive(remote); b.receive(own); a.receive(remote); b.receive(own);
        const merged = a.getSnapshot().blocks, replica = b.getSnapshot().blocks;
        const anchors = [a.resolvePosition(positionA).offset, a.resolvePosition(positionB).offset];
        const reopened = runtime.restoreWriting(a.save(), actorID);
        reopened.undo(); b.receive(reopened.changes()); const undo = reopened.getSnapshot().blocks;
        reopened.redo(); b.receive(reopened.changes()); b.receive(reopened.changes());
        samples.push({ version, actorID, length, merged, replica, anchors, undo, redo: reopened.getSnapshot().blocks, redoReplica: b.getSnapshot().blocks });
        a.close(); b.close(); reopened.close(); continue;
      }
      const savedA = a.save(), savedB = b.save(), beforeA = JSON.stringify(savedA), beforeB = JSON.stringify(savedB);
      const receiptA = JSON.stringify(a.syncState()), receiptB = JSON.stringify(b.syncState());
      const proposalA = pending(() => a.receive(remote)), proposalB = pending(() => b.receive(own));
      const repeated = [pending(() => a.receive(remote)), pending(() => a.receive(remote))];
      pending(() => a.undo()); pending(() => a.replaceText(address, 0, 0, "blocked"));
      const acceptedPreserved = JSON.stringify(a.save()) === beforeA && JSON.stringify(b.save()) === beforeB
        && JSON.stringify(a.syncState()) === receiptA && JSON.stringify(b.syncState()) === receiptB;
      const ra = runtime.restoreWriting(savedA, actorID), rb = runtime.restoreWriting(savedB, "m");
      const restoredA = pending(() => ra.restoreRecovery(proposalA)), restoredB = pending(() => rb.restoreRecovery(proposalB));
      const restartPreserved = JSON.stringify(ra.save()) === beforeA && JSON.stringify(rb.save()) === beforeB
        && JSON.stringify(ra.syncState()) === receiptA && JSON.stringify(rb.syncState()) === receiptB;
      const origin = ra.node({ blockID: "math", path: [] });
      let failedRepair = "";
      try { ra.repairText(origin, "expression", "x".repeat(9_999) + suffix); } catch (error) { failedRepair = (error as Error).message; }
      const failedPreserved = JSON.stringify(ra.save()) === beforeA && JSON.stringify(ra.mergeRecovery()) === JSON.stringify(proposalA);
      ra.repairText(origin, "expression", "x".repeat(9_998) + suffix);
      const merged = ra.getSnapshot().blocks, anchors = [ra.resolvePosition(positionA).offset, ra.resolvePosition(positionB).offset];
      const forward = ra.changes(), reverse = { ...forward, changes: [...forward.changes].reverse() };
      rb.receive(reverse); rb.receive(forward); rb.receive(reverse);
      const replica = rb.getSnapshot().blocks;
      const reopened = runtime.restoreWriting(ra.save(), actorID), beforeUndo = JSON.stringify(reopened.save()), undoReceipt = JSON.stringify(reopened.syncState());
      const pendingUndo = pending(() => reopened.undo());
      const rejectedUndoPreserved = JSON.stringify(reopened.save()) === beforeUndo && JSON.stringify(reopened.syncState()) === undoReceipt;
      reopened.repairRedo({ counter: 2, actor: actorID }); rb.receive(reopened.changes()); rb.receive(reopened.changes());
      samples.push({ version, actorID, length, merged, replica, anchors, proposalA, proposalB, repeated, restoredA, restoredB,
        acceptedPreserved, restartPreserved, failedRepair, failedPreserved, pendingUndo, rejectedUndoPreserved,
        redo: reopened.getSnapshot().blocks, redoReplica: rb.getSnapshot().blocks, finalChanges: reopened.changes().changes.length });
      a.close(); b.close(); ra.close(); rb.close(); reopened.close();
    }
    return samples;
  }, `/block-editor/@fs${process.cwd()}`);
  const rich = { id: "rich", type: "paragraph", host: "retained", content: [
    { type: "text", text: "café 東京😀", marks: [{ type: "bold" }] },
    { type: "entity-ref", entityType: "task", entityId: "outside", label: "Task", consumer: { id: "reference-opaque" } },
  ] };
  const expected = (suffix: string) => [{ id: "math", type: "math", expression: "x".repeat(9_998) + suffix,
    consumer: { id: "math-opaque", children: [{ id: "opaque-child" }] } }, rich];
  expect(samples).toHaveLength(8);
  for (const sample of samples) {
    const suffix = sample.actorID === "z" ? "AB" : "BA";
    expect(sample.merged).toEqual(expected(suffix)); expect(sample.replica).toEqual(expected(suffix));
    expect(sample.anchors).toEqual(sample.actorID === "z" ? [9_999, 10_000] : [10_000, 9_999]);
    expect(sample.redo).toEqual(expected(suffix)); expect(sample.redoReplica).toEqual(expected(suffix));
    if (sample.length === 9_998) { expect(sample.undo).toEqual(expected("B")); continue; }
    expect(sample.proposalA).toEqual(sample.proposalB);
    expect(sample.proposalA.reason).toBe("schemaConstraint"); expect(sample.proposalA.batch.version).toBe(sample.version);
    expect(sample.proposalA.batch.changes).toHaveLength(2);
    expect(sample.repeated).toEqual([sample.proposalA, sample.proposalA]);
    expect(sample.restoredA).toEqual(sample.proposalA); expect(sample.restoredB).toEqual(sample.proposalB);
    expect(sample.acceptedPreserved && sample.restartPreserved && sample.failedPreserved && sample.rejectedUndoPreserved).toBe(true);
    expect(sample.failedRepair).toBe("invalidChange"); expect(sample.pendingUndo.reason).toBe("schemaConstraint");
    expect(sample.pendingUndo.batch.changes).toHaveLength(4); expect(sample.finalChanges).toBe(5);
  }
});

test("typed v5 whole-block paste orders concurrent cut groups and preserves author history", async ({ page }) => {
  await page.route("**/writing-engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const result = await page.evaluate(async root => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("writing-engine.wasm")).arrayBuffer());
    const seed = [{ id: "p", type: "paragraph", host: "boundary", content: [{ type: "text", text: "abcd", marks: [] }] }];
    const imported = {
      id: "input", type: "paragraph",
      content: [{ type: "text", text: "東京😀", marks: [{ type: "bold" }] },
        { type: "entity-ref", entityType: "task", entityId: "consumer-task", label: "Task", consumer: { id: "reference-opaque" } }],
      consumer: { id: "opaque-owner", children: [{ id: "opaque-child" }] },
    };
    const clipboard = { version: 1, parts: [{ node: { value: imported, kind: "block" } }] };
    const address = { blockID: "p", path: ["content"] };
    const cases = [];
    for (const actorID of ["a", "z"]) for (const cut of [1, 2]) {
      const documentID = `typed-splice-${actorID}-${cut}`;
      const a = runtime.createWritingV5({ documentID, actorID, epoch: "five", blocks: seed });
      const b = runtime.createWritingV5({ documentID, actorID: "m", epoch: "five", blocks: seed });
      const range = a.selectedText(address, cut, cut);
      const held = JSON.stringify(a.save());
      const release = a.deferRemoteChanges();
      let heldError = "", compositionError = "";
      try { a.pasteBlocks(clipboard, range); } catch (error) { heldError = (error as Error).message; }
      const heldPreserved = JSON.stringify(a.save()) === held;
      release();
      a.setComposing(true);
      try { a.pasteBlocks(clipboard, range); } catch (error) { compositionError = (error as Error).message; }
      a.setComposing(false);
      const compositionPreserved = JSON.stringify(a.save()) === held;
      const caret = a.pasteBlocks(clipboard, range);
      const authored = a.changes().changes.length;
      const peerCut = cut === 1 ? 2 : 1;
      b.splitParagraph(address, peerCut, peerCut, "peer-tail");
      const own = a.changes(), remote = b.changes();
      a.receive(remote);
      b.receive(own);
      a.receive(remote);
      b.receive(own);
      const accepted = a.getSnapshot().blocks, replica = b.getSnapshot().blocks;
      const resolved = a.resolvePosition(caret), tail = a.node({ blockID: `paste-${actorID}-1-2`, path: [] });
      const reopened = runtime.restoreWriting(a.save(), actorID);
      reopened.undo();
      b.receive(reopened.changes());
      const undo = reopened.getSnapshot(), undoReplica = b.getSnapshot().blocks;
      reopened.redo();
      b.receive(reopened.changes());
      b.receive(reopened.changes());
      cases.push({ actorID, cut, authored, heldError, compositionError, heldPreserved, compositionPreserved,
        accepted, replica, resolved, tail, undo, undoReplica, redo: reopened.getSnapshot().blocks, redoReplica: b.getSnapshot().blocks });
      a.close(); b.close(); reopened.close();
    }
    const zero = runtime.createWritingV5({ documentID: "typed-splice-zero", actorID: "a", epoch: "five", blocks: seed });
    const four = runtime.createWritingV4({ documentID: "typed-splice-zero", actorID: "old", epoch: "five", blocks: seed });
    const caret = zero.pasteBlocks(clipboard, zero.selectedText(address, 0, 2));
    const accepted = zero.getSnapshot().blocks, saved = JSON.stringify(zero.save()), oldSaved = JSON.stringify(four.save());
    const errors = [];
    const operations = [
      () => four.pasteBlocks(clipboard, four.selectedText(address, 0, 0)),
      () => zero.receive(four.changes()),
      () => four.receive(zero.changes()),
      () => zero.pasteBlocks(zero.clipboardText("inline"), zero.selectedText(address, 0, 0)),
      () => zero.pasteBlocks(clipboard, {
        start: zero.position({ blockID: "paste-a-1-1", path: ["content"] }, 0),
        end: zero.position(address, 1),
      }),
    ];
    for (const operation of operations) {
      try { operation(); errors.push("missing rejection"); } catch (error) { errors.push((error as Error).message); }
    }
    const rejectedPreserved = JSON.stringify(zero.save()) === saved && JSON.stringify(four.save()) === oldSaved;
    const recoveryEmpty = zero.mergeRecovery() === null && four.mergeRecovery() === null;
    const resolved = zero.resolvePosition(caret), original = zero.node({ blockID: "p", path: [] });
    const authored = zero.changes().changes.length;
    zero.undo(); const undo = zero.getSnapshot().blocks;
    zero.redo(); const redo = zero.getSnapshot().blocks;
    zero.close(); four.close();
    return { cases, zero: { accepted, resolved, original, authored, errors, rejectedPreserved, recoveryEmpty, undo, redo } };
  }, `/block-editor/@fs${process.cwd()}`);

  const paragraph = (id: string, text: string, host = false) => ({ id, type: "paragraph", content: [{ type: "text", text, marks: [] }], ...(host ? { host: "boundary" } : {}) });
  const imported = (id: string) => ({
    id, type: "paragraph", content: [{ type: "text", text: "東京😀", marks: [{ type: "bold" }] },
      { type: "entity-ref", entityType: "task", entityId: "consumer-task", label: "Task", consumer: { id: "reference-opaque" } }],
    consumer: { id: "opaque-owner", children: [{ id: "opaque-child" }] },
  });
  for (const sample of result.cases) {
    const middle = imported(`paste-${sample.actorID}-1-1`), tail = `paste-${sample.actorID}-1-2`;
    const expected = sample.cut === 1 ? [paragraph("p", "a", true), middle, paragraph(tail, "b", true), paragraph("peer-tail", "cd")]
      : [paragraph("p", "a", true), paragraph("peer-tail", "b"), middle, paragraph(tail, "cd", true)];
    const undo = sample.cut === 1 ? [paragraph("p", "ab", true), paragraph("peer-tail", "cd")]
      : [paragraph("p", "a", true), paragraph("peer-tail", "bcd")];
    expect(sample.authored).toBe(1);
    expect(sample.heldError).toBe("Commit composition before pasting");
    expect(sample.compositionError).toBe("compositionActive");
    expect(sample.heldPreserved && sample.compositionPreserved).toBe(true);
    expect(sample.accepted).toEqual(expected);
    expect(sample.replica).toEqual(expected);
    expect(sample.resolved.offset).toBe(0);
    expect(sample.resolved.address.identity).toEqual(sample.tail);
    expect(sample.undo.blocks).toEqual(undo);
    expect(sample.undoReplica).toEqual(undo);
    expect(sample.undo.canUndo).toBe(false);
    expect(sample.undo.canRedo).toBe(true);
    expect(sample.redo).toEqual(expected);
    expect(sample.redoReplica).toEqual(expected);
  }
  expect(result.zero.accepted).toEqual([imported("paste-a-1-1"), paragraph("p", "cd", true)]);
  expect(result.zero.resolved.address.identity).toEqual(result.zero.original);
  expect(result.zero.authored).toBe(1);
  expect(result.zero.errors).toEqual(["unsupportedVersion(4)", "unsupportedVersion(4)", "unsupportedVersion(5)", "invalidPath", "invalidPath"]);
  expect(result.zero.rejectedPreserved && result.zero.recoveryEmpty).toBe(true);
  expect(result.zero.undo).toEqual([paragraph("p", "abcd", true)]);
  expect(result.zero.redo).toEqual(result.zero.accepted);
});


test("typed v5 epoch rejects mixed versions and inherits Unicode undo and recovery", async ({ page }) => {
  await page.route("**/writing-engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const result = await page.evaluate(async root => {
    const { SwiftEditorRuntime, SwiftWritingRecoveryError } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("writing-engine.wasm")).arrayBuffer());
    const blocks = [{ id: "p", type: "paragraph", host: "keep", content: [{ type: "text", text: "C", marks: [] }] }];
    const a = runtime.createWritingV5({ documentID: "typed-five", actorID: "a", epoch: "explicit-five", blocks });
    const b = runtime.createWritingV5({ documentID: "typed-five", actorID: "b", epoch: "explicit-five", blocks });
    const four = runtime.createWritingV4({ documentID: "typed-five", actorID: "four", epoch: "explicit-five", blocks });
    const address = { blockID: "p", path: ["content"] };
    a.replaceText(address, 0, 0, "東京"); const caret = a.replaceText(address, 2, 2, "X"), offset = a.resolvePosition(caret).offset;
    b.replaceText(address, 1, 1, "R"); a.receive(b.changes()); a.receive(b.changes()); b.receive(a.changes());
    const accepted = a.save(), fourAccepted = four.save(), snapshot = a.getSnapshot().blocks, replica = b.getSnapshot().blocks;
    const errors = [];
    for (const operation of [() => a.receive(four.changes()), () => four.receive(a.changes()), () => runtime.call({ command: "create", session: "unsupported-five", collaborationVersion: 6, documentID: "unknown", actorID: "a", epoch: "unknown", blocks: [] })]) {
      try { operation(); throw new Error("Missing version rejection"); } catch (error) { errors.push((error as Error).message); }
    }
    const mixedPreserved = JSON.stringify(a.save()) === JSON.stringify(accepted) && JSON.stringify(four.save()) === JSON.stringify(fourAccepted) && a.mergeRecovery() === null && four.mergeRecovery() === null;
    const restored = runtime.restoreWriting(accepted, "a"); restored.undo(); const undo = restored.getSnapshot().blocks;
    restored.redo(); const redo = restored.getSnapshot().blocks, version = restored.save().version, receiptVersion = restored.syncState().version;
    a.close(); b.close(); four.close(); restored.close();

    const ra = runtime.createWritingV5({ documentID: "typed-five-recovery", actorID: "a", epoch: "five-recovery", blocks: [] });
    const rb = runtime.createWritingV5({ documentID: "typed-five-recovery", actorID: "peer", epoch: "five-recovery", blocks: [] });
    const math = ra.insertCollectionNodes([{ id: "math", type: "math", expression: "x+y", extension: { remote: false } }], { field: "blocks" }).nodes[0];
    const birth = ra.changes(); rb.receive(birth);
    rb.receive({ ...birth, changes: [{ id: { counter: 2, actor: "peer" }, observed: [{ counter: 1, actor: "a" }], body: { edit: { _0: [{ structure: { _0: { setNodeField: { identity: math, path: ["extension", "remote"], value: true } } } }] } } }] });
    ra.receive(rb.changes()); const recoveryAccepted = ra.save(), receipt = JSON.stringify(ra.syncState());
    const recover = (operation: () => void) => {
      try { operation(); } catch (error) { if (error instanceof SwiftWritingRecoveryError) return error.recovery; throw error; }
      throw new Error("Missing typed v5 recovery");
    };
    const pending = recover(() => ra.undo());
    const pendingPreserved = JSON.stringify(ra.save()) === JSON.stringify(recoveryAccepted) && JSON.stringify(ra.syncState()) === receipt;
    const resumed = runtime.restoreWriting(recoveryAccepted, "a"); recover(() => resumed.restoreRecovery(JSON.parse(JSON.stringify(pending))));
    let failedRepair = false; try { resumed.repairText(math, "expression", ""); } catch (error) { failedRepair = (error as Error).message === "invalidChange"; }
    const failedPreserved = JSON.stringify(resumed.save()) === JSON.stringify(recoveryAccepted) && JSON.stringify(resumed.mergeRecovery()) === JSON.stringify(pending);
    resumed.repairText(math, "expression", "restored 😀"); rb.receive(resumed.changes());
    const repaired = resumed.getSnapshot().blocks, repairedReplica = rb.getSnapshot().blocks, recoveryVersion = pending.batch.version, recoveryCount = pending.batch.changes.length;
    const repairedVersion = resumed.save().version, repairedCount = resumed.changes().changes.length, cleared = resumed.mergeRecovery() === null;
    ra.close(); rb.close(); resumed.close();
    return { snapshot, replica, undo, redo, offset, errors, mixedPreserved, version, receiptVersion, pendingPreserved, failedRepair, failedPreserved, repaired, repairedReplica, recoveryVersion, recoveryCount, repairedVersion, repairedCount, cleared };
  }, `/block-editor/@fs${process.cwd()}`);
  const expected = (text: string) => [{ id: "p", type: "paragraph", host: "keep", content: [{ type: "text", text, marks: [] }] }];
  expect(result.snapshot).toEqual(expected("東京XCR")); expect(result.replica).toEqual(result.snapshot);
  expect(result.undo).toEqual(expected("東京CR")); expect(result.redo).toEqual(result.snapshot);
  expect(result.offset).toBe(3); expect(result.version).toBe(5); expect(result.receiptVersion).toBe(5);
  expect(result.errors).toEqual(["unsupportedVersion(4)", "unsupportedVersion(5)", "unsupportedVersion(6)"]);
  expect(result.mixedPreserved && result.pendingPreserved && result.failedRepair && result.failedPreserved && result.cleared).toBe(true);
  expect(result.recoveryVersion).toBe(5); expect(result.recoveryCount).toBe(3); expect(result.repairedVersion).toBe(5); expect(result.repairedCount).toBe(4);
  expect(result.repaired).toEqual([{ id: "math", type: "math", expression: "restored 😀", extension: { remote: true } }]);
  expect(result.repairedReplica).toEqual(result.repaired);
});


test("typed v4 clipboard keeps Unicode references and peer undo in one history action", async ({ page }) => {
  await page.route("**/writing-engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const results = await page.evaluate(async root => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("writing-engine.wasm")).arrayBuffer());
    const results = [];
    for (const actorID of ["a", "z"]) {
      const blocks = [{ id: "p", type: "paragraph", host: "retained", content: [{ type: "text", text: "ABC", marks: [] }] }];
      const a = runtime.createWritingV4({ documentID: "typed-clipboard-" + actorID, actorID, epoch: "clipboard-v4", blocks });
      const b = runtime.createWritingV4({ documentID: "typed-clipboard-" + actorID, actorID: "m", epoch: "clipboard-v4", blocks });
      const address = { blockID: "p", path: ["content"] }, range = a.selectedText(address, 1, 2);
      const reference = { type: "entity-ref", entityType: "task", entityId: "external-id", label: "Task", consumer: { id: "opaque" } };
      const clipboard = { version: 1, parts: [{ inline: { _0: [{ type: "text", text: "東京😀", marks: [{ type: "bold" }] }, reference] } }] };
      b.replaceText(address, 3, 3, " peer"); a.receive(b.changes());
      const release = a.deferRemoteChanges(), held = JSON.stringify(a.save()); let blocked = false;
      try { a.pasteInline(clipboard, range); } catch { blocked = true; }
      const heldPreserved = held === JSON.stringify(a.save()); release();
      const count = a.changes().changes.length, caret = a.pasteInline(clipboard, range);
      const offset = a.resolvePosition(caret).offset, added = a.changes().changes.length - count;
      const accepted = a.getSnapshot().blocks; b.receive(a.changes()); b.receive(a.changes());
      const copied = a.copyClipboard({ nodes: [], text: [a.selectedText(address, 1, 9)] });
      const reopened = runtime.restoreWriting(a.save(), actorID);
      reopened.undo(); const undo = reopened.getSnapshot(), canUndo = undo.canUndo;
      reopened.redo(); const redo = reopened.getSnapshot().blocks;
      results.push({ blocked, heldPreserved, offset, added, accepted, replica: b.getSnapshot().blocks, copied, undo: undo.blocks, canUndo, redo });
      a.close(); b.close(); reopened.close();
    }
    return results;
  }, `/block-editor/@fs${process.cwd()}`);
  for (const result of results) {
    expect(result.blocked && result.heldPreserved).toBe(true);
    expect(result.offset).toBe(9); expect(result.added).toBe(1); expect(result.canUndo).toBe(false);
    expect(result.accepted).toEqual([{ id: "p", type: "paragraph", host: "retained", content: [
      { type: "text", text: "A", marks: [] }, { type: "text", text: "東京😀", marks: [{ type: "bold" }] },
      { type: "entity-ref", entityType: "task", entityId: "external-id", label: "Task", consumer: { id: "opaque" } },
      { type: "text", text: "C peer", marks: [] },
    ] }]);
    expect(result.replica).toEqual(result.accepted); expect(result.redo).toEqual(result.accepted);
    expect(result.undo).toEqual([{ id: "p", type: "paragraph", host: "retained", content: [{ type: "text", text: "ABC peer", marks: [] }] }]);
    expect(result.copied.parts[0].inline._0.at(-1)).toMatchObject({ entityId: "external-id", consumer: { id: "opaque" } });
  }
});


test("typed v4 sequential input follows observed Unicode and preserves peer undo", async ({ page }) => {
  await page.route("**/writing-engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const results = await page.evaluate(async root => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("writing-engine.wasm")).arrayBuffer());
    const results = [];
    for (const list of [false, true]) for (const actorID of ["a", "z"]) {
      const content = [{ type: "text", text: "C", marks: [{ type: "bold" }] }];
      const blocks = list ? [{ id: "p", type: "list", style: "todo", host: "owner", items: [{ id: "i", content, checked: true, host: "item" }] }]
        : [{ id: "p", type: "paragraph", content, host: "original" }];
      const documentID = `typed-boundary-${list}-${actorID}`;
      const a = runtime.createWritingV4({ documentID, actorID, epoch: "boundary-v4", blocks });
      const b = runtime.createWritingV4({ documentID, actorID: "m", epoch: "boundary-v4", blocks });
      const address = { blockID: "p", path: list ? ["items", "i", "content"] : ["content"] };
      a.replaceText(address, 0, 0, "東京");
      const caret = a.replaceText(address, 2, 2, "X"), offset = a.resolvePosition(caret).offset;
      const typed = a.getSnapshot().blocks;
      b.replaceText(address, 1, 1, "R"); const remote = b.changes(); a.receive(remote); a.receive(remote);
      b.receive(a.changes()); const replica = b.getSnapshot().blocks;
      const reopened = runtime.restoreWriting(a.save(), actorID), accepted = reopened.getSnapshot().blocks;
      reopened.undo(); const undo = reopened.getSnapshot().blocks;
      reopened.redo(); const redo = reopened.getSnapshot().blocks;
      results.push({ list, offset, typed, replica, accepted, undo, redo });
      reopened.close(); a.close(); b.close();
    }
    return results;
  }, `/block-editor/@fs${process.cwd()}`);
  for (const result of results) {
    const nodes = (blocks: typeof result.typed) => result.list ? blocks[0].items! : blocks;
    const texts = (blocks: typeof result.typed) => nodes(blocks).map(node => node.content!.map(run => run.type === "text" ? run.text : "").join(""));
    expect(result.offset).toBe(3);
    expect(texts(result.typed)).toEqual(["東京XC"]);
    expect(texts(result.accepted)).toEqual(["東京XCR"]);
    expect(result.replica).toEqual(result.accepted);
    expect(texts(result.undo)).toEqual(["東京CR"]);
    expect(result.redo).toEqual(result.accepted);
    for (const node of nodes(result.redo)) for (const run of node.content!) expect(run).toMatchObject({ marks: [{ type: "bold" }] });
    if (result.list) expect(nodes(result.redo)[0]).toMatchObject({ checked: true, host: "item" });
    else expect(nodes(result.redo)[0]).toMatchObject({ host: "original" });
  }
});

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

test("typed v4 rejected author undo survives restart and permits explicit text or redo repair", async ({ page }) => {
  await page.route("**/writing-engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const results = await page.evaluate(async root => {
    const { SwiftEditorRuntime, SwiftWritingRecoveryError } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("writing-engine.wasm")).arrayBuffer());
    const outcomes = [];
    for (const actor of ["a", "z"]) for (const repair of ["redo", "text"]) {
      const rich = { id: "rich", type: "paragraph", host: "keep", content: [{ type: "text", text: "café 😀", marks: [{ type: "bold" }] }, { type: "entity-ref", entityType: "note", entityId: "external", label: "Reference" }] };
      const blocks = [rich], documentID = `typed-undo-${actor}-${repair}`;
      const a = runtime.createWritingV4({ documentID, actorID: actor, epoch: "undo-v4", blocks });
      const b = runtime.createWritingV4({ documentID, actorID: "peer", epoch: "undo-v4", blocks });
      const math = a.insertCollectionNodes([{ id: "math", type: "math", expression: "x+y", extension: { remote: false, later: 0 } }], { field: "blocks" }).nodes[0];
      const creation = { counter: 1, actor }, birth = a.changes(); b.receive(birth);
      const peer = (counter: number, key: string, value: unknown, observed: unknown[]) => ({ ...birth, changes: [{ id: { counter, actor: "peer" }, observed, body: { edit: { _0: [{ structure: { _0: { setNodeField: { identity: math, path: ["extension", key], value } } } }] } } }] });
      b.receive(peer(2, "remote", true, [creation])); a.receive(b.changes());
      const accepted = a.save(), receipts = JSON.stringify(a.syncState());
      const recover = (operation: () => void) => {
        try { operation(); } catch (error) { if (error instanceof SwiftWritingRecoveryError) return error.recovery; throw error; }
        throw new Error("Expected typed writing recovery");
      };
      const initial = recover(() => a.undo()); recover(() => a.redo());
      b.receive(peer(3, "later", 7, [creation, { counter: 2, actor: "peer" }]));
      const pending = recover(() => a.receive(b.changes())); recover(() => a.receive(b.changes()));
      const preserved = JSON.stringify(a.save()) === JSON.stringify(accepted) && JSON.stringify(a.syncState()) === receipts;
      const resumed = runtime.restoreWriting(accepted, actor); recover(() => resumed.restoreRecovery(pending));
      const pendingBefore = JSON.stringify(resumed.mergeRecovery());
      for (const operation of [() => resumed.repairRedo({ counter: 2, actor: "peer" }), () => resumed.repairText(math, "children", "bad"), () => resumed.repairText({ baseline: { blockID: "rich", path: [] } }, "content", "café 😀RefeXrence"), () => resumed.repairText(math, "expression", "")]) {
        let rejected = false; try { operation(); } catch { rejected = true; }
        if (!rejected) throw new Error("Expected failed repair");
      }
      const failedPreserved = JSON.stringify(resumed.save()) === JSON.stringify(accepted) && JSON.stringify(resumed.mergeRecovery()) === pendingBefore && JSON.stringify(resumed.syncState()) === receipts;
      if (repair === "redo") resumed.repairRedo(creation); else resumed.repairText(math, "expression", "restored x+y 😀");
      b.receive(resumed.changes()); b.receive(resumed.changes());
      const reopened = runtime.restoreWriting(resumed.save(), actor);
      outcomes.push({ actor, repair, initial, pending, preserved, failedPreserved, repaired: resumed.getSnapshot().blocks, replica: b.getSnapshot().blocks, reopened: reopened.getSnapshot().blocks, changeCount: resumed.changes().changes.length, clear: resumed.mergeRecovery() });
      a.close(); b.close(); resumed.close(); reopened.close();
    }
    return outcomes;
  }, `/block-editor/@fs${process.cwd()}`);
  for (const result of results) {
    expect(result.initial).toMatchObject({ reason: "schemaConstraint", batch: { version: 4, changes: expect.any(Array) } });
    expect(result.initial.batch.changes).toHaveLength(3); expect(result.pending.batch.changes).toHaveLength(4);
    expect(result.preserved && result.failedPreserved).toBe(true);
    expect(result.repaired).toEqual([{ id: "math", type: "math", expression: result.repair === "redo" ? "x+y" : "restored x+y 😀", extension: { remote: true, later: 7 } }, { id: "rich", type: "paragraph", host: "keep", content: [{ type: "text", text: "café 😀", marks: [{ type: "bold" }] }, { type: "entity-ref", entityType: "note", entityId: "external", label: "Reference" }] }]);
    expect(result.replica).toEqual(result.repaired); expect(result.reopened).toEqual(result.repaired);
    expect(result.changeCount).toBe(5); expect(result.clear).toBeNull();
  }
});
