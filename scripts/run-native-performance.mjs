import { spawn, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFileSync, writeFileSync, mkdirSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { cpus, totalmem, platform, arch, release } from 'node:os';
import { resolve, dirname } from 'node:path';
import { performanceOptions, runPerformance } from './performance.mjs';

const binary = resolve(process.argv[2] ?? '.build/release/editor-bridge');
const output = resolve(process.argv[3] ?? 'test-results/performance/performance-native.json');
const source = readFileSync('benchmarks/workloads.json');
const config = JSON.parse(source);
const options = performanceOptions(config, {
  profile: process.env.PERFORMANCE_PROFILE,
  cases: process.env.PERFORMANCE_CASES?.split(','),
  repetitions: process.env.PERFORMANCE_REPETITIONS === undefined ? undefined : Number(process.env.PERFORMANCE_REPETITIONS),
  warmups: process.env.PERFORMANCE_WARMUPS === undefined ? undefined : Number(process.env.PERFORMANCE_WARMUPS),
});
mkdirSync(dirname(output), { recursive: true });
const report = {
  version: 1, workloadHash: createHash('sha256').update(source).digest('hex'), options,
  sourceCommit: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
  sourceDirty: execFileSync('git', ['status', '--porcelain'], { encoding: 'utf8' }).trim().length > 0,
  runtime: { name: 'native', platform: platform(), architecture: arch(), osRelease: release(), cpu: cpus()[0]?.model, memoryBytes: totalmem(), hostRuntime: process.version, binary, boundary: 'editor-bridge process; JSON serialization, pipes and response parsing included' },
  artifacts: [{ name: 'editor-bridge', rawBytes: statSync(binary).size, sha256: createHash('sha256').update(readFileSync(binary)).digest('hex'), configuration: 'caller-supplied binary; use release build for baseline measurements' }],
  samples: [], complete: false,
};
const start = performance.now();
const child = spawn(binary, [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
const terminated = new Promise((resolve, reject) => {
  child.on('error', reject);
  child.on('exit', (code, signal) => code === 0 ? resolve() : reject(new Error(`Bridge exited ${code ?? signal}`)));
});
terminated.catch(() => {});
const call = async input => {
  child.stdin.write(`${JSON.stringify(input)}\n`);
  const line = await lines.next();
  if (line.done) throw new Error('Bridge terminated before its response');
  return JSON.parse(line.value);
};
const publish = () => writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`);
// Invalidate any earlier successful output before starting this measurement.
publish();
let failure;
try {
  const response = await call({ command: 'create', session: 'startup', actorID: 'startup', documentID: 'startup', blocks: [] });
  if (!response.ok) throw new Error(response.error);
  report.initialization = { freshProcessToFirstEmptySessionMs: performance.now() - start, diskCaches: 'uncontrolled; not disk-cold startup' };
  await call({ command: 'close', session: 'startup' });
  await runPerformance(config, options, call, sample => {
    report.samples.push(sample); publish();
    console.log(`${sample.case} repeat ${sample.repetition}: edits p95 ${sample.metrics.offlineEdit.p95Ms.toFixed(2)} ms; rejoin ${sample.metrics.rejoin.totalMs.toFixed(2)} ms; snapshot ${sample.sizes.snapshotBytes} bytes`);
  });
  report.complete = true;
} catch (error) { failure = error; report.error = String(error); report.complete = false; }
finally {
  child.stdin.end();
  try { await terminated; }
  catch (error) { failure ??= error; report.error = String(failure); report.complete = false; }
  publish();
}
if (failure) throw failure;
