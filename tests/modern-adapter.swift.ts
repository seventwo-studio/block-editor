import { test, expect } from "@playwright/test";
import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { createHash } from "node:crypto";
import type { ModernDocument } from "../src/swift-modern.js";

test("typed protocol 7 consumer contract through actual browser WASM", async ({ page }, testInfo) => {
  // The whole 55-fixture/22-command consumer run is slower on hosted WebKit than local builds.
  test.setTimeout(120_000);
  const root = resolve("docs/acceptance/modern-editor/documents");
  const fixtures = readdirSync(root).filter(name => name.endsWith(".json")).flatMap(name => {
    const bytes = readFileSync(resolve(root, name)), document = JSON.parse(bytes.toString()) as ModernDocument;
    return document.format === "seventwo.block-editor.document" ? [{ name, document }] : [];
  });
  const wasm = resolve(process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm");
  await page.route("**/modern-engine.wasm", route => route.fulfill({ path: wasm, contentType: "application/wasm" }));
  await page.goto("/");
  const result = await page.evaluate(async ({ root, fixtures }) => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const { runModernAdapterContract } = await import(/* @vite-ignore */ `${root}/tests/modern-adapter.contract.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("modern-engine.wasm")).arrayBuffer());
    return runModernAdapterContract(runtime, fixtures);
  }, { root: `/block-editor/@fs${process.cwd()}`, fixtures });
  expect(result.fixtures).toBe(55); expect(result.checks).toHaveLength(11);
  expect(result.appliedCommands).toHaveLength(22);
  await testInfo.attach("modern-adapter-contract", { body: JSON.stringify({ ...result, wasmSHA256: createHash("sha256").update(readFileSync(wasm)).digest("hex") }, null, 2), contentType: "application/json" });
});
