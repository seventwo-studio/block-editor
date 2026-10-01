import { test } from '@playwright/test';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { gzipSync } from 'node:zlib';
import { resolve } from 'node:path';
import { cpus, totalmem, platform, arch, release } from 'node:os';

test('measures verified editing and offline-history workloads through WASM', async ({ page, browser }, testInfo) => {
  testInfo.setTimeout(1_800_000);
  const output = resolve(process.env.PERFORMANCE_OUTPUT ?? 'test-results/performance');
  mkdirSync(output, { recursive: true });
  const source = readFileSync('benchmarks/workloads.json');
  const wasm = readFileSync(process.env.BLOCK_EDITOR_WASM ?? 'dist/block-editor.wasm');
  const report: Record<string, unknown> = {
    version: 1, workloadHash: createHash('sha256').update(source).digest('hex'),
    sourceCommit: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
    sourceDirty: execFileSync('git', ['status', '--porcelain'], { encoding: 'utf8' }).trim().length > 0,
    runtime: { name: `wasm-${testInfo.project.name}`, browser: browser.version(), host: { platform: platform(), architecture: arch(), osRelease: release(), cpu: cpus()[0]?.model, memoryBytes: totalmem() }, boundary: 'SwiftEditorRuntime.call; UTF-8/JSON and WASM copies included; rendering/network excluded' },
    artifacts: [{ name: 'block-editor.wasm', rawBytes: wasm.length, gzipBytes: gzipSync(wasm, { level: 9 }).length, sha256: createHash('sha256').update(wasm).digest('hex'), configuration: 'release, stripped debug; gzip level 9 is computed, not a delivery claim' }],
    samples: [], complete: false,
  };
  const publish = () => writeFileSync(`${output}/performance-wasm-${testInfo.project.name}.json`, `${JSON.stringify(report, null, 2)}\n`);
  publish();
  await page.exposeFunction('publishPerformanceSample', (sample: unknown) => { (report.samples as unknown[]).push(sample); publish(); });
  await page.route('**/engine.wasm', route => route.fulfill({ body: wasm, contentType: 'application/wasm' }));
  try {
    await page.goto('/');
    const metadata = await page.evaluate(async ({ config, root, options }) => {
      const { SwiftEditorRuntime } = await import(/* @vite-ignore */ `${root}/src/swift.ts`);
      const { performanceOptions, runPerformance } = await import(/* @vite-ignore */ `${root}/scripts/performance.mjs`);
      const bytes = await (await fetch('engine.wasm')).arrayBuffer();
      const startCompile = performance.now();
      const module = await WebAssembly.compile(bytes);
      const compileMs = performance.now() - startCompile;
      const startInstance = performance.now();
      const runtime = await SwiftEditorRuntime.initialize(module);
      const compiledModuleInstanceMs = performance.now() - startInstance;
      const firstCall = performance.now();
      runtime.call({ command: 'create', session: 'startup', actorID: 'startup', documentID: 'startup', blocks: [] });
      const firstEmptySessionMs = performance.now() - firstCall;
      runtime.call({ command: 'close', session: 'startup' });
      const selected = performanceOptions(config, options);
      await runPerformance(config, selected, async (request: Record<string, unknown>) => ({ ok: true, value: runtime.call(request) }),
        (sample: unknown) => (window as unknown as { publishPerformanceSample: (sample: unknown) => Promise<void> }).publishPerformanceSample(sample));
      return { options: selected, initialization: { compileMs, compiledModuleInstanceMs, firstEmptySessionMs, diskCaches: 'uncontrolled; fetched local bytes before timing; not disk-cold startup' }, environment: { userAgent: navigator.userAgent, hardwareConcurrency: navigator.hardwareConcurrency } };
    }, { config: JSON.parse(source.toString()), root: `/block-editor/@fs${process.cwd()}`, options: {
      profile: process.env.PERFORMANCE_PROFILE,
      cases: process.env.PERFORMANCE_CASES?.split(','),
      repetitions: process.env.PERFORMANCE_REPETITIONS === undefined ? undefined : Number(process.env.PERFORMANCE_REPETITIONS),
      warmups: process.env.PERFORMANCE_WARMUPS === undefined ? undefined : Number(process.env.PERFORMANCE_WARMUPS),
    } });
    Object.assign(report, metadata, { complete: true });
  } catch (error) { report.error = String(error); throw error; }
  finally { publish(); }
  await testInfo.attach('performance', { path: `${output}/performance-wasm-${testInfo.project.name}.json`, contentType: 'application/json' });
});
