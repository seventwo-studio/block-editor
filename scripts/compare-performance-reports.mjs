import { readFileSync, readdirSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { isDeepStrictEqual } from 'node:util';
import { canonical } from './compatibility.mjs';
import { performanceOptions, summarize } from './performance.mjs';

export function validatePerformanceReport(report, config) {
  if (report.version !== 1 || report.complete !== true || report.error) throw new Error('Incomplete/failed performance report');
  const options = performanceOptions(config, { ...report.options, cases: report.options?.cases?.map(x => x.name) });
  if (!isDeepStrictEqual(canonical(options), canonical(report.options))) throw new Error('Workload options do not match the configuration');
  if (!/^[a-f0-9]{40}$/.test(report.sourceCommit)) throw new Error('Missing source revision');
  if (!report.runtime?.name || !report.initialization || !Array.isArray(report.artifacts) || !report.artifacts.length) throw new Error('Missing runtime/initialization/artifact evidence');
  for (const [key, value] of Object.entries(report.initialization)) {
    if (key.endsWith('Ms') && (!Number.isFinite(value) || value < 0)) throw new Error('Invalid initialization timing');
  }
  if (!Object.keys(report.initialization).some(x => x.endsWith('Ms'))) throw new Error('Missing measured initialization');
  for (const artifact of report.artifacts) {
    if (!Number.isInteger(artifact.rawBytes) || artifact.rawBytes <= 0 || !/^[a-f0-9]{64}$/.test(artifact.sha256)) throw new Error('Invalid artifact size/hash');
  }
  if (!Array.isArray(report.samples) || report.samples.length !== options.cases.length * options.repetitions) throw new Error('Missing/extra measurement samples');
  const seen = new Set();
  for (const sample of report.samples) {
    const workload = options.cases.find(x => x.name === sample.case);
    if (!workload || sample.version !== workload.version || sample.editsPerAuthor !== workload.editsPerAuthor || !Number.isInteger(sample.repetition) || sample.repetition < 0 || sample.repetition >= options.repetitions) throw new Error('Unexpected sample workload');
    const key = `${sample.case}/${sample.repetition}`;
    if (seen.has(key)) throw new Error('Duplicated measurement sample');
    seen.add(key);
    const counts = { create: 3, offlineEdit: workload.editsPerAuthor * 2, format: 2, exchangeExport: 2, rejoin: 2, duplicateReceive: 1, fullHistoryReceive: 1, save: 1, receipts: 2, restore: 1, undo: 2, redo: 2 };
    if (!isDeepStrictEqual(Object.keys(sample.metrics ?? {}).sort(), Object.keys(counts).sort())) throw new Error('Missing/extra measurement phases');
    for (const [phase, count] of Object.entries(counts)) {
      const metric = sample.metrics[phase];
      if (metric.count !== count || !Array.isArray(metric.samplesMs) || metric.samplesMs.length !== count) throw new Error(`Incomplete ${phase} measurements`);
      const actual = summarize(metric.samplesMs);
      for (const key of ['totalMs', 'minMs', 'p50Ms', 'p95Ms', 'maxMs']) {
        if (!Number.isFinite(metric[key]) || Math.abs(actual[key] - metric[key]) > 1e-6) throw new Error(`Incorrect ${phase} ${key}`);
      }
    }
    if (sample.sizes?.changes !== workload.editsPerAuthor * 2 + 2 || sample.sizes?.receipts !== sample.sizes.changes) throw new Error('Incomplete retained history/receipts');
    for (const key of ['baselineBytes', 'snapshotBytes', 'exchangeBytes']) if (!Number.isInteger(sample.sizes[key]) || sample.sizes[key] <= 0) throw new Error('Missing serialized sizes');
    if (!Array.isArray(sample.finalBlocks) || sample.finalBlocks.length !== config.baseline.length) throw new Error('Missing final document');
  }
  return options;
}

function files(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? files(join(dir, entry.name)) : [join(dir, entry.name)]);
}

export function comparePerformanceReports(root, expected, requiredProfile) {
  const source = readFileSync('benchmarks/workloads.json');
  const config = JSON.parse(source);
  const hash = createHash('sha256').update(source).digest('hex');
  const revision = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  const candidates = files(root).filter(path => path.endsWith('.json')).flatMap(path => {
    const value = JSON.parse(readFileSync(path, 'utf8'));
    return value.workloadHash ? [{ path, value }] : [];
  });
  const reports = expected.map(name => {
    const matching = candidates.filter(x => x.value.runtime?.name === name);
    if (matching.length !== 1) throw new Error(`Expected exactly one ${name} performance report, found ${matching.length}`);
    const { value } = matching[0];
    validatePerformanceReport(value, config);
    if (value.workloadHash !== hash || value.sourceCommit !== revision) throw new Error(`${name}: stale workload/source`);
    if (requiredProfile && !isDeepStrictEqual(canonical(value.options), canonical(performanceOptions(config, { profile: requiredProfile })))) throw new Error(`${name}: incomplete required ${requiredProfile} profile`);
    return { name, value };
  });
  for (const { name, value } of reports.slice(1)) {
    if (!isDeepStrictEqual(canonical(value.options), canonical(reports[0].value.options))) throw new Error(`${name}: differing measured workloads`);
    const results = report => canonical(report.samples.map(x => ({ case: x.case, repetition: x.repetition, finalBlocks: x.finalBlocks, changes: x.sizes.changes, receipts: x.sizes.receipts })).sort((a, b) => `${a.case}/${a.repetition}`.localeCompare(`${b.case}/${b.repetition}`)));
    if (!isDeepStrictEqual(results(value), results(reports[0].value))) throw new Error(`${name}: differing measured documents/histories`);
  }
  return reports;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const expected = (process.argv[3] ?? 'native,android-api26-x86_64,android-api35-x86_64,android-api35-arm64-v8a,wasm-chromium,wasm-webkit,wasm-firefox').split(',');
  const reports = comparePerformanceReports(resolve(process.argv[2] ?? 'test-results/performance'), expected, process.argv[4]);
  console.log(`Verified ${reports.length} complete measurement reports with matching workloads and preserved documents; no numeric performance budget is asserted.`);
}
