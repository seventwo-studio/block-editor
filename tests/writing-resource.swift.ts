import { test } from '@playwright/test';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
const source = readFileSync('benchmarks/resources-writing.json');
const spec = JSON.parse(source.toString()) as { protocols: number[]; cases: string[] };
const hash = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');
const git = (...args: string[]) => execFileSync('git', args, { encoding: 'utf8' }).trim();
for (const version of spec.protocols) for (const caseName of spec.cases) test(`actual writing resource v${version} ${caseName}`, async ({ page }, info) => {
  info.setTimeout(900_000);
  const output = resolve(process.env.RESOURCE_OUTPUT ?? 'test-results/resource'); mkdirSync(output, { recursive: true });
  const wasm = readFileSync(process.env.BLOCK_EDITOR_WASM ?? 'dist/block-editor.wasm');
  const report: Record<string, unknown> = { version: 1, kind: 'compact-production-resource-proof', runtime: `wasm-${info.project.name}`, protocol: version, case: caseName,
    specSHA256: hash(source), source: { commit: git('rev-parse', 'HEAD'), tree: git('rev-parse', 'HEAD^{tree}'), dirty: !!git('status', '--porcelain', '--untracked-files=all') },
    artifacts: [{ name: 'block-editor.wasm', role: 'wasm', rawBytes: wasm.length, sha256: hash(wasm) }],
    boundary: 'Actual browser WASM shared JSON bridge; real production limits; UI/rendering/physical host acceptance excluded', complete: false };
  const file = `${output}/resource-writing-wasm-${info.project.name}-v${version}-${caseName}.json`;
  const publish = () => writeFileSync(file, `${JSON.stringify(report, null, 2)}\n`); publish();
  let failure: unknown;
  try {
    await page.route('**/engine.wasm', route => route.fulfill({ body: wasm, contentType: 'application/wasm' }));
    await page.goto('/');
    report.proof = await page.evaluate(async ({ spec, version, caseName, root }) => {
      const { SwiftEditorRuntime, SwiftWritingRecoveryError, SwiftMergeRecoveryError } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
      const { runWritingResourceCase } = await import(/* @vite-ignore */ `${root}/scripts/writing-resource.mjs`);
      const runtime = await SwiftEditorRuntime.initialize(await (await fetch('engine.wasm')).arrayBuffer());
      return runWritingResourceCase(spec, version, caseName, async (request: Record<string, unknown>) => {
        try { return { ok: true, value: runtime.call(request) }; }
        catch (error) {
          if (error instanceof SwiftWritingRecoveryError) return { ok: false, error: 'writingRecoveryRequired', recovery: error.recovery };
          if (error instanceof SwiftMergeRecoveryError) return { ok: false, error: 'mergeRecoveryRequired', recovery: error.recovery };
          if (!(error instanceof Error)) throw error; return { ok: false, error: error.message };
        }
      }, async (bytes: Uint8Array<ArrayBuffer>) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(x => x.toString(16).padStart(2, '0')).join(''));
    }, { spec, version, caseName, root: `/block-editor/@fs${process.cwd()}` });
    report.complete = true;
  } catch (error) { failure = error; report.error = String(error); throw error; }
  finally {
    try { publish(); } catch (diagnostic) { if (failure === undefined) throw diagnostic; console.error("Resource report persistence failed", diagnostic); }
  }
  await info.attach('production-resource-proof', { path: file, contentType: 'application/json' });
});
