import { test, expect } from "@playwright/test";
import { resolve } from "node:path";
test("modern relay rejects original malformed wire before peer admission", async ({ page }, info) => {
  await page.route("**/modern-engine.wasm", route => route.fulfill({ path: resolve(process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm"), contentType: "application/wasm" }));
  await page.goto(`/block-editor/@fs${process.cwd()}/tests/helpers/modern-surface.html`);
  const result = await page.evaluate(async root => {
    const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
    const { runModernRelayWireContract } = await import(/* @vite-ignore */ `${root}/tests/modern-relay-wire.contract.ts`);
    const runtime = await SwiftEditorRuntime.initialize(await (await fetch("modern-engine.wasm")).arrayBuffer());
    return runModernRelayWireContract(runtime);
  }, `/block-editor/@fs${process.cwd()}`);
  await info.attach("original-wire-contract", { body: JSON.stringify(result), contentType: "application/json" });
  expect(result.checks).toEqual(["duplicate", "rounded", "utf8", "surrogate", "valid signed-zero GET/exchange/paired reopen", "malformed fresh GET without local replacement"]);
});
