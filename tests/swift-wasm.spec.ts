import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

test("recovery fixture retains rejected histories and converges after repair and restart in WASM", async ({ page }) => {
  const fixture = JSON.parse(readFileSync("tests/BlockEditorCoreTests/Fixtures/recovery.json", "utf8"));
  await page.route("**/engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const captured = await page.evaluate(async ({ source, fixture }) => {
    const { SwiftEditorRuntime, SwiftMergeRecoveryError } = await import(/* @vite-ignore */ source);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("engine.wasm")).arrayBuffer());
    const captured: Record<string, any> = {};
    for (const step of fixture.steps) {
      const request = { ...step.request };
      for (const [key, binding] of Object.entries(step.bindings ?? {})) {
        const path = Array.isArray(binding) ? binding : [binding];
        request[key] = path.reduce((value, part) => value[part], captured);
      }
      try {
        const value = runtime.call(request);
        if (step.error) throw new Error("Expected a rejected merge");
        if (step.capture) captured[step.capture] = value;
      } catch (error) {
        if (step.error === "mergeRecoveryRequired") {
          if (!(error instanceof SwiftMergeRecoveryError)) throw error;
          if (step.capture) captured[step.capture] = error.recovery;
        } else {
          if (!step.error || !(error instanceof Error) || error.message !== step.error) throw error;
          if (step.capture) throw new Error("Only merge recovery errors expose a capture value");
        }
      }
    }
    return captured;
  }, { source: `/block-editor/@fs${process.cwd()}/src/swift.ts`, fixture });
  for (const [left, right] of fixture.equal) expect(captured[left]).toEqual(captured[right]);
  expect(captured.cleared).toBeNull();
  expect(captured.proposalA.reason).toBe("identityConflict");
  expect(captured.proposalA.batch.changes).toHaveLength(2);
  expect(captured.finalA).toEqual(fixture.expected);
  expect(captured.afterUndo).toEqual(fixture.expectedAfterUndo);
});

test("typed WASM recovery APIs expose failed repairs and survive a host-retained proposal", async ({ page }) => {
  await page.route("**/engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const result = await page.evaluate(async source => {
    const { SwiftEditorRuntime, SwiftMergeRecoveryError } = await import(/* @vite-ignore */ source);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("engine.wasm")).arrayBuffer());
    const a = runtime.create({ documentID: "typed-recovery", actorID: "a", blocks: [], collaborationVersion: 2 });
    const b = runtime.create({ documentID: "typed-recovery", actorID: "b", blocks: [], collaborationVersion: 2 });
    let restarted;
    try {
      a.insertNode({ id: "same", type: "paragraph", content: [{ type: "text", text: "Alice", marks: [] }] }, { field: "blocks" });
      const second = b.insertNode({ id: "same", type: "paragraph", content: [{ type: "text", text: "Bob", marks: [] }] }, { field: "blocks" });
      const saved = a.save(); let reason;
      try { a.receive(b.changes()); } catch (error) { if (!(error instanceof SwiftMergeRecoveryError)) throw error; reason = error.recovery.reason; }
      const retained = JSON.parse(JSON.stringify(a.mergeRecovery()));
      restarted = runtime.restore(saved, "a");
      try { restarted.receive(retained.batch); } catch (error) { if (!(error instanceof SwiftMergeRecoveryError)) throw error; }
      let failed = false;
      try { restarted.repairMerge([{ move: { identity: second, collection: { field: "blocks" } } }]); } catch { failed = true; }
      const preserved = JSON.stringify(restarted.save()) === JSON.stringify(saved);
      restarted.repairMerge([{ wrap: { identity: second, container: { id: "wrapper", type: "toggle", summary: [], children: [] }, field: "children" } }]);
      b.receive(restarted.changes());
      return { reason, failed, preserved, cleared: restarted.mergeRecovery(), converged: JSON.stringify(b.getSnapshot().blocks) === JSON.stringify(restarted.getSnapshot().blocks),
        address: restarted.nodeAddress(second), texts: JSON.stringify(restarted.getSnapshot().blocks) };
    } finally { a.close(); b.close(); restarted?.close(); }
  }, `/block-editor/@fs${process.cwd()}/src/swift.ts`);
  expect(result).toMatchObject({ reason: "identityConflict", failed: true, preserved: true, cleared: null, converged: true, address: { blockID: "wrapper", path: ["children", "same"] } });
  expect(result.texts).toContain("Alice"); expect(result.texts).toContain("Bob");
});

test("out-of-order concurrent formatting preserves independent marks and author undo", async ({ page }) => {
  await page.route("**/engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const stages = await page.evaluate(async source => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ source);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("engine.wasm")).arrayBuffer());
    const blocks = [{ id: "p", type: "paragraph", content: [{ type: "text", text: "ABC", marks: [] }] }];
    const a = runtime.create({ documentID: "marks", actorID: "a", blocks });
    const b = runtime.create({ documentID: "marks", actorID: "b", blocks });
    const address = { blockID: "p", path: ["content"] };
    try {
      a.format(address, 0, 3, "bold", { type: "bold" });
      b.replaceText(address, 1, 1, "😀"); b.format(address, 0, 5, "italic", { type: "italic" });
      const batch = b.changes();
      for (const change of [...batch.changes].reverse()) a.receive({ ...batch, changes: [change, change] });
      b.receive(a.changes());
      const stages = [b.getSnapshot().blocks[0].content];
      a.undo(); b.receive(a.changes()); stages.push(b.getSnapshot().blocks[0].content);
      a.redo(); b.receive(a.changes()); stages.push(b.getSnapshot().blocks[0].content);
      b.undo(); a.receive(b.changes()); stages.push(a.getSnapshot().blocks[0].content);
      return stages;
    } finally { a.close(); b.close(); }
  }, `/block-editor/@fs${process.cwd()}/src/swift.ts`);
  const node = (text: string, ...marks: string[]) => ({ type: "text", text, marks: marks.map(type => ({ type })) });
  const combined = [node("A", "bold", "italic"), node("😀", "italic"), node("BC", "bold", "italic")];
  expect(stages).toEqual([combined, [node("A😀BC", "italic")], combined, [node("A", "bold"), node("😀"), node("BC", "bold")]]);
});

test("migration corpus preserves rich documents and rejects invalid known shapes in WASM", async ({ page }) => {
  const corpus = JSON.parse(readFileSync("tests/BlockEditorCoreTests/Fixtures/documents.json", "utf8"));
  await page.route("**/engine.wasm", route => route.fulfill({ path: "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const result = await page.evaluate(async ({ source, corpus }) => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ source);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("engine.wasm")).arrayBuffer());
    const documents = [], rejected = [];
    for (const sample of corpus.valid) {
      const editor = runtime.create({ documentID: sample.name, actorID: "local", blocks: sample.blocks });
      const restored = runtime.restore(editor.save(), "local");
      documents.push(restored.getSnapshot().blocks); editor.close(); restored.close();
    }
    for (const sample of corpus.invalid) {
      try { const editor = runtime.create({ documentID: sample.name, actorID: "local", blocks: sample.blocks }); editor.close(); rejected.push(false); }
      catch { rejected.push(true); }
    }
    return { documents, rejected };
  }, { source: `/block-editor/@fs${process.cwd()}/src/swift.ts`, corpus });
  expect(result.documents).toEqual(corpus.valid.map((sample: { blocks: unknown }) => sample.blocks));
  expect(result.rejected).toEqual(corpus.invalid.map(() => true));
});

test("shared bridge compatibility fixture matches native Swift", async ({ page }) => {
  const fixture = JSON.parse(readFileSync("tests/BlockEditorCoreTests/Fixtures/bridge.json", "utf8"));
  await page.route("**/engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const result = await page.evaluate(async ({ source, requests }) => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ source);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("engine.wasm")).arrayBuffer());
    let result;
    for (const request of requests) result = runtime.call(request);
    return result;
  }, { source: `/block-editor/@fs${process.cwd()}/src/swift.ts`, requests: fixture.requests });
  expect(result).toEqual(fixture.expected);
});

test("versioned nested structure fixture matches Swift through actual WASM", async ({ page }) => {
  const fixture = JSON.parse(readFileSync("tests/BlockEditorCoreTests/Fixtures/structure.json", "utf8"));
  await page.route("**/engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const captured = await page.evaluate(async ({ source, steps }) => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ source);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("engine.wasm")).arrayBuffer());
    const captured: Record<string, unknown> = {};
    for (const step of steps) {
      const request = { ...step.request };
      for (const [key, name] of Object.entries(step.bindings ?? {})) request[key] = captured[name as string];
      const value = runtime.call(request);
      if (step.capture) captured[step.capture] = value;
    }
    return captured;
  }, { source: `/block-editor/@fs${process.cwd()}/src/swift.ts`, steps: fixture.steps });
  for (const [left, right] of fixture.equal ?? []) {
    expect(captured[left], left).toBeDefined(); expect(captured[right], right).toBeDefined();
    expect(captured[left], `${left}/${right}`).toEqual(captured[right]);
  }
  expect(captured.final).toEqual(fixture.expected);
  expect(captured.resolvedPosition).toBe(fixture.expectedPosition);
  expect(captured.cutover).toEqual(fixture.expectedCutover);
  expect(captured.cutoverChanges).toMatchObject({ version: 2 });
});

test("typed WASM node APIs retain remote content through undo and reopen", async ({ page }) => {
  await page.route("**/engine.wasm", route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  const result = await page.evaluate(async source => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ source);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("engine.wasm")).arrayBuffer());
    const a = runtime.create({ documentID: "typed-nodes", actorID: "a", blocks: [], collaborationVersion: 2 });
    const b = runtime.create({ documentID: "typed-nodes", actorID: "b", blocks: [], collaborationVersion: 2 });
    try {
      const node = a.insertNode({ id: "p", type: "paragraph", content: [{ type: "text", text: "local", marks: [] }] }, { field: "blocks" });
      b.receive(a.changes());
      b.replaceText(b.textAddress(node), 5, 5, "REMOTE");
      a.undo(); a.receive(b.changes()); b.receive(a.changes());
      const restored = runtime.restore(a.save(), "observer");
      try {
        return { blocks: restored.getSnapshot().blocks, address: restored.nodeAddress(node), count: restored.nodes({ field: "blocks" }).length,
          converged: JSON.stringify(a.getSnapshot().blocks) === JSON.stringify(b.getSnapshot().blocks) };
      } finally { restored.close(); }
    } finally { a.close(); b.close(); }
  }, `/block-editor/@fs${process.cwd()}/src/swift.ts`);
  expect(result).toEqual({ blocks: [{ id: "p", type: "paragraph", content: [{ type: "text", text: "REMOTE", marks: [] }] }], address: { blockID: "p", path: [] }, count: 1, converged: true });
});

test("real Swift WASM converges, preserves remote edits during undo, and saves offline", async ({ page }) => {
  const artifact = process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm";
  await page.route("**/engine.wasm", route => route.fulfill({ path: artifact, contentType: "application/wasm" }));
  await page.goto("/");
  const result = await page.evaluate(async ({ source }) => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ source);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("engine.wasm")).arrayBuffer());
    const blocks = [{ id: "p", type: "paragraph", content: [{ type: "text", text: "Hi 😀", marks: [] }] }];
    const a = runtime.create({ documentID: "doc", actorID: "a", blocks });
    const b = runtime.create({ documentID: "doc", actorID: "b", blocks });
    const address = { blockID: "p", path: ["content"] };
    a.replaceText(address, 5, 5, " Alice");
    b.replaceText(address, 5, 5, " Bob");
    const left = a.changes(), right = b.changes();
    a.receive(right); b.receive(left); b.receive(left);
    const converged = JSON.stringify(a.getSnapshot().blocks) === JSON.stringify(b.getSnapshot().blocks);
    a.undo(); b.receive(a.changes(b.syncState()));
    const beforePresence = JSON.stringify(a.save());
    a.receivePresence({ actor: "b", revision: 1, address });
    const saved = a.save();
    const restored = runtime.restore(saved, "reopened");
    const result = {
      converged,
      text: a.getSnapshot().blocks[0].content.map((n: { text: string }) => n.text).join(""),
      reopened: JSON.stringify(restored.getSnapshot().blocks) === JSON.stringify(a.getSnapshot().blocks),
      ephemeral: beforePresence === JSON.stringify(saved),
      noPending: a.changes(b.syncState()).changes.length === 0,
    };
    a.close(); b.close(); restored.close();
    return result;
  }, { source: `/block-editor/@fs${process.cwd()}/src/swift.ts` });
  expect(result).toEqual({ converged: true, text: "Hi 😀 Bob", reopened: true, ephemeral: true, noPending: true });
});

test("invalid WASM fails explicitly", async ({ page }) => {
  await page.goto("/");
  const failed = await page.evaluate(async (source) => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ source);
    try { await SwiftEditorRuntime.initialize(new Uint8Array([0, 1, 2])); return false; }
    catch { return true; }
  }, `/block-editor/@fs${process.cwd()}/src/swift.ts`);
  expect(failed).toBe(true);
});

test("React reference edits offline and exchanges Swift changes", async ({ page, context }) => {
  await page.goto("/block-editor/swift.html");
  const alice = page.getByRole("region", { name: "Alice" });
  const bob = page.getByRole("region", { name: "Bob" });
  await expect(alice.getByRole("textbox")).toBeVisible();
  await expect(bob.getByRole("textbox")).toBeVisible();
  await context.setOffline(true);
  await alice.getByRole("textbox").fill("Alice edited offline");
  await page.getByRole("button", { name: "Exchange changes" }).click();
  await expect(bob.getByRole("textbox")).toHaveText("Alice edited offline");
  await alice.getByRole("button", { name: "Undo", exact: true }).click();
  await page.getByRole("button", { name: "Exchange changes" }).click();
  await expect(bob.getByRole("textbox")).toHaveText("Edit together, or work offline.");
});

test("reference reconnects, shows ephemeral presence and reopens a saved file offline", async ({ page, context, browserName }, testInfo) => {
  test.fixme(browserName === "webkit", "File.text() returns NotReadableError in offline WebKit automation, including byte-backed uploads; file reopen acceptance remains open.");
  await page.goto("/block-editor/swift.html");
  const alice = page.getByRole("region", { name: "Alice" });
  const bob = page.getByRole("region", { name: "Bob" });
  await expect(alice.getByRole("textbox")).toBeVisible();
  await expect(bob.getByRole("textbox")).toBeVisible();
  await context.setOffline(true);
  await alice.getByRole("textbox").fill("Saved while offline 😀");
  await page.getByLabel("Connect editors", { exact: true }).check();
  await expect(bob.getByRole("textbox")).toHaveText("Saved while offline 😀");
  await bob.getByRole("textbox").focus();
  await expect(page.getByText("Bob is editing.", { exact: true })).toBeVisible();
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Save local document" }).click();
  const path = testInfo.outputPath("saved.json");
  await (await download).saveAs(path);
  const snapshot = JSON.parse(readFileSync(path, "utf8"));
  expect(snapshot.presence).toBeUndefined();
  await alice.getByRole("textbox").fill("Unsaved replacement");
  // Exercise the browser File API with the exact saved bytes.
  await page.getByLabel("Reopen local document").setInputFiles({ name: "saved.json", mimeType: "application/json", buffer: readFileSync(path) });
  await expect(page.getByRole("status").filter({ hasText: "Reopened locally" })).toBeVisible();
  await expect(alice.getByRole("textbox")).toHaveText("Saved while offline 😀");
  await expect(bob.getByRole("textbox")).toHaveText("Saved while offline 😀");
  await expect(page.getByLabel("Connect editors", { exact: true })).not.toBeChecked();
});
