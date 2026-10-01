import { test, expect } from 'bun:test';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error The shared measurement verifier is plain ESM.
import { validatePerformanceReport, comparePerformanceReports } from '../scripts/compare-performance-reports.mjs';

// Use an actual engine report, not synthetic timings or a simulated editor.
const report = JSON.parse(readFileSync(process.env.PERFORMANCE_REPORT ?? 'test-results/performance/performance-native.json', 'utf8'));
const config = JSON.parse(readFileSync('benchmarks/workloads.json', 'utf8'));

test('accepts the complete measured engine report', () => {
  expect(() => validatePerformanceReport(report, config)).not.toThrow();
});

test('compares canonical reports beside Playwright attachments but rejects duplicate outputs', () => {
  const root = mkdtempSync(join(tmpdir(), 'editor-measurement-artifacts-'));
  try {
    const canonical = join(root, `performance-${report.runtime.name}.json`);
    writeFileSync(canonical, JSON.stringify(report));
    const attachments = join(root, 'playwright', 'attachments');
    mkdirSync(attachments, { recursive: true });
    writeFileSync(join(attachments, 'performance-diagnostic-copy.json'), JSON.stringify(report));
    expect(comparePerformanceReports(root, [report.runtime.name], undefined, report.sourceCommit)).toHaveLength(1);
    const duplicate = join(root, 'duplicate-run');
    mkdirSync(duplicate);
    writeFileSync(join(duplicate, `performance-${report.runtime.name}.json`), JSON.stringify(report));
    expect(() => comparePerformanceReports(root, [report.runtime.name], undefined, report.sourceCommit)).toThrow('found 2');
    rmSync(duplicate, { recursive: true });
    writeFileSync(canonical, JSON.stringify({ ...report, runtime: { ...report.runtime, name: 'wrong-runtime' } }));
    expect(() => comparePerformanceReports(root, [report.runtime.name], undefined, report.sourceCommit)).toThrow('incorrect report runtime');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('rejects missing samples even when the report claims completion', () => {
  const changed = structuredClone(report);
  changed.samples.pop();
  expect(() => validatePerformanceReport(changed, config)).toThrow('Missing/extra measurement samples');
});

test('rejects missing calls with an internally consistent shorter timing summary', () => {
  const changed = structuredClone(report);
  const metric = changed.samples[0].metrics.offlineEdit;
  metric.samplesMs.pop(); metric.count--;
  expect(() => validatePerformanceReport(changed, config)).toThrow('Incomplete offlineEdit measurements');
});

test('rejects changing the history workload to a shorter unrecorded test', () => {
  const changed = structuredClone(report);
  changed.options.cases[0].editsPerAuthor--;
  expect(() => validatePerformanceReport(changed, config)).toThrow('Workload options');
});

test('rejects invalid clocks and fabricated aggregates', () => {
  for (const corrupt of [(metric: { samplesMs: number[] }) => { metric.samplesMs[0] = -1; },
    (metric: { totalMs: number }) => { metric.totalMs += 1; }]) {
    const changed = structuredClone(report);
    corrupt(changed.samples[0].metrics.offlineEdit);
    expect(() => validatePerformanceReport(changed, config)).toThrow();
  }
});

test('rejects failed reports and incomplete receipt retention', () => {
  const failed = structuredClone(report); failed.error = 'receive failed';
  expect(() => validatePerformanceReport(failed, config)).toThrow('Incomplete/failed');
  const changed = structuredClone(report); changed.samples[0].sizes.receipts--;
  expect(() => validatePerformanceReport(changed, config)).toThrow('Incomplete retained history/receipts');
});
