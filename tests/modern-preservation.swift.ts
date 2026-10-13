import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createHash } from "node:crypto";
import type { PreservationCase } from "./modern-preservation.contract.js";

for (const scenario of ["paired-reopen", "migration-activation", "migration-refusal", "large-migration"] as const satisfies readonly PreservationCase[]) {
  test(`modern preservation: ${scenario}`, async ({ page }, testInfo) => {
    test.setTimeout(120_000);
    const fixtures = Object.fromEntries(["columns-7000", "legacy-mixed", "migrated-mixed", "legacy-collision", "unsupported-inline", "legacy-5001", "migrated-5001"].map(name => {
      const raw = readFileSync(resolve("docs/acceptance/modern-editor/documents", `${name}.json`), "utf8");
      return [name, { raw, document: JSON.parse(raw) }];
    }));
    const wasm = resolve(process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm");
    await page.route("**/modern-engine.wasm", route => route.fulfill({ path: wasm, contentType: "application/wasm" }));
    await page.goto("/");
    const result = await page.evaluate(async ({ root, fixtures, scenario }) => {
      const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
      const { runModernPreservation } = await import(/* @vite-ignore */ `${root}/tests/modern-preservation.contract.ts`);
      const runtime = await SwiftEditorRuntime.initialize(await (await fetch("modern-engine.wasm")).arrayBuffer());
      return runModernPreservation(runtime, fixtures, scenario);
    }, { root: `/block-editor/@fs${process.cwd()}`, fixtures, scenario });
    expect(result.checks.length).toBeGreaterThan(0);
    await testInfo.attach("modern-preservation", { body: JSON.stringify({ ...result, browserVersion: page.context().browser()?.version(), wasmSHA256: createHash("sha256").update(readFileSync(wasm)).digest("hex") }, null, 2), contentType: "application/json" });
  });
}
