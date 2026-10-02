import { spawn, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFileSync, writeFileSync, mkdirSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { cpus, totalmem, platform, arch, release } from 'node:os';
import { resolve, dirname } from 'node:path';
import { performanceOptions, runPerformance } from './performance.mjs';

const binary = resolve(process.argv[2] ?? '.build/release/editor-bridge');
const output = resolve(process.argv[3] ?? (process.env.PERFORMANCE_WRITING === 'true' ? 'test-results/performance/performance-writing-native.json' : 'test-results/performance/performance-native.json'));
const writing = process.env.PERFORMANCE_WRITING === 'true';
const source = readFileSync(writing ? 'benchmarks/workloads-writing.json' : 'benchmarks/workloads.json');
const config = JSON.parse(source);
if (writing && !['debug', 'release'].includes(process.env.PERFORMANCE_BINARY_CONFIGURATION)) throw new Error('Writing measurements require an explicit debug/release artifact configuration');
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
  sourceTree: execFileSync('git', ['rev-parse', 'HEAD^{tree}'], { encoding: 'utf8' }).trim(), numericBudgets: 'unagreed',
  runtime: { name: 'native', platform: platform(), architecture: arch(), osRelease: release(), cpu: cpus()[0]?.model, memoryBytes: totalmem(), hostRuntime: process.version, binary, boundary: 'editor-bridge process; JSON serialization, pipes and response parsing included' },
  artifacts: [{ name: 'editor-bridge', rawBytes: statSync(binary).size, sha256: createHash('sha256').update(readFileSync(binary)).digest('hex'), configuration: writing ? process.env.PERFORMANCE_BINARY_CONFIGURATION : 'caller-supplied binary; use release build for baseline measurements' }],
  samples: [], complete: false,
};
const start = performance.now();
if (writing && platform() !== 'darwin') throw new Error('Writing peak-memory measurements require macOS /usr/bin/time -l');
const child = spawn(writing ? '/usr/bin/time' : binary, writing ? ['-l', binary] : [], { stdio: ['pipe', 'pipe', writing ? 'pipe' : 'inherit'] });
let resources = '';
if (writing) { child.stderr.setEncoding('utf8'); child.stderr.on('data', chunk => { resources += chunk; }); }
const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
const terminated = new Promise((resolve, reject) => {
  child.on('error', reject);
  child.on('close', (code, signal) => code === 0 ? resolve() : reject(new Error(`Bridge exited ${code ?? signal}`)));
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
  const response = await call({ command: 'create', session: 'startup', actorID: 'startup', documentID: 'startup', blocks: [], ...(writing ? { collaborationVersion: options.cases[0].version, epoch: `performance-writing-v${options.cases[0].version}` } : {}) });
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
  if (writing) {
    writeFileSync(`${output}.resources.txt`, resources);
    const rss = resources.match(/(?:^|\n)\s*(\d+)\s+maximum resident set size/);
    if (!rss || !Number.isSafeInteger(Number(rss[1])) || Number(rss[1]) <= 0) {
      failure ??= new Error('Missing valid native child peak memory'); report.error = String(failure); report.complete = false;
    } else report.memory = { maximumResidentSetSizeBytes: Number(rss[1]), method: 'macOS /usr/bin/time -l', boundary: 'Peak editor-bridge child across measured workloads; rendering and parent runner excluded' };
  }
  publish();
}
if (failure) throw failure;
