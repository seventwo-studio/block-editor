import { test, expect } from "@playwright/test";
import { resolve } from "node:path";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
test("modern relay durable ACK, delayed scope and held-input lifecycle through actual WASM and IndexedDB", async ({ page }, info) => {
  await page.route("**/modern-engine.wasm", route => route.fulfill({ path: resolve(process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm"), contentType: "application/wasm" }));
  await page.goto(`/block-editor/@fs${process.cwd()}/tests/helpers/modern-surface.html`);
  const result = await page.evaluate(async root => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const { runModernRelayClientContract } = await import(/* @vite-ignore */ `${root}/tests/modern-relay-client.contract.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("modern-engine.wasm")).arrayBuffer());
    return runModernRelayClientContract(runtime);
  }, `/block-editor/@fs${process.cwd()}`);
  expect(result.checks).toHaveLength(4);
  await info.attach("modern-relay-client-contract", { body: JSON.stringify({ ...result,
    source: process.env.EVIDENCE_SOURCE_SHA ?? execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
    wasmSHA256: createHash("sha256").update(readFileSync(resolve(process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm"))).digest("hex"),
  }, null, 2), contentType: "application/json" });
});
