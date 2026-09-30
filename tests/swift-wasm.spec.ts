import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

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
