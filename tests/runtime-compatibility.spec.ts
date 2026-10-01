import { test } from '@playwright/test';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
// @ts-expect-error Shared runtime harness is plain ESM for Node and browser use.
import { fixtureNames, canonical } from '../scripts/compatibility.mjs';

test('publishes shared fixture responses from actual browser WASM', async ({ page }, testInfo) => {
  testInfo.setTimeout(120_000);
  const output = resolve(process.env.COMPATIBILITY_OUTPUT ?? 'test-results/compatibility');
  mkdirSync(output, { recursive: true });
  const report = { version: 1, fixtureHashes: {} as Record<string, string>, fixtures: {} as Record<string, unknown> };
  await page.route('**/engine.wasm', route => route.fulfill({ path: process.env.BLOCK_EDITOR_WASM ?? 'dist/block-editor.wasm', contentType: 'application/wasm' }));
  await page.goto('/');
  for (const name of fixtureNames as string[]) {
    const source = readFileSync(`tests/BlockEditorCoreTests/Fixtures/${name}.json`);
    report.fixtureHashes[name] = createHash('sha256').update(source).digest('hex');
    try {
      report.fixtures[name] = await page.evaluate(async ({ name, fixture, root }) => {
        const { SwiftEditorRuntime, SwiftMergeRecoveryError } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
        const { runFixture } = await import(/* @vite-ignore */ `${root}/scripts/compatibility.mjs`);
        const runtime = await SwiftEditorRuntime.initialize(await (await fetch('engine.wasm')).arrayBuffer());
        return runFixture(name, fixture, async (request: unknown) => {
          try { return { ok: true, value: runtime.call(request) }; }
          catch (error) {
            if (error instanceof SwiftMergeRecoveryError) return { ok: false, error: 'mergeRecoveryRequired', recovery: error.recovery };
            if (!(error instanceof Error)) throw error;
            return { ok: false, error: error.message };
          }
        });
      }, { name, fixture: JSON.parse(source.toString()), root: `/block-editor/@fs${process.cwd()}` });
    } finally {
      writeFileSync(`${output}/wasm-${testInfo.project.name}.json`, `${JSON.stringify(canonical(report), null, 2)}\n`);
    }
  }
  await testInfo.attach('runtime-responses', { path: `${output}/wasm-${testInfo.project.name}.json`, contentType: 'application/json' });
});
