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
