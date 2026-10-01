import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gunzipSync } from "node:zlib";
// @ts-expect-error The measurement verifier is plain ESM.
import { validatePerformanceReport } from "../scripts/compare-performance-reports.mjs";

const bundle = "benchmarks/results/2026-10-01-v3-native-release";
const metadata = JSON.parse(readFileSync(`${bundle}/provenance.json`, "utf8"));
const hash = (bytes: Uint8Array) =>
  createHash("sha256").update(bytes).digest("hex");

test("validates the six preserved native v3 measurements and exact workload", () => {
  const bytes = readFileSync(`${bundle}/performance-native.json`);
  const report = JSON.parse(bytes.toString());
  const workload = readFileSync("benchmarks/workloads-v3.json");
  expect(() =>
    validatePerformanceReport(report, JSON.parse(workload.toString())),
  ).not.toThrow();
  expect(hash(bytes)).toBe(
    metadata.publishedFilesSHA256["performance-native.json"],
  );
  expect(report.workloadHash).toBe(hash(workload));
  expect(report.sourceOverlayTree).toBe(metadata.sourceOverlayTree);
  expect(report.sourceDirty).toBe(true);
});

test("preserves the complete qualified compatibility transcript losslessly", () => {
  const bytes = gunzipSync(
    readFileSync(`${bundle}/compatibility-transcript.json.gz`),
  );
  expect(hash(bytes)).toBe(metadata.compatibilitySHA256);
  const report = JSON.parse(bytes.toString());
  const counts = Object.values(report.fixtures).map(
    (value) => (value as { responses: unknown[] }).responses.length,
  );
  expect(counts.reduce((sum, count) => sum + count, 0)).toBe(2934);
  expect(report.fixtures.recovery.responses).toHaveLength(665);
});

test("refuses legacy workloads, invalid source stamps and mismatched artifacts before execution", () => {
  const root = mkdtempSync(join(tmpdir(), "v3-measurement-guards-"));
  try {
    const binary = join(root, "not-an-engine");
    const output = join(root, "report.json");
    const stamp = join(root, "source.json");
    writeFileSync(binary, "artifact mismatch fixture");
    const run = (workload: string, source?: object) => {
      const args = [
        "scripts/run-native-v3-performance.mjs",
        binary,
        output,
        workload,
      ];
      if (source) {
        writeFileSync(stamp, JSON.stringify(source));
        args.push(stamp);
      }
      return spawnSync(process.execPath, args, { encoding: "utf8" });
    };
    const legacy = run("benchmarks/workloads.json");
    expect(legacy.status).not.toBe(0);
    expect(legacy.stderr).toContain("V3 runner requires version 3 cases");
    const invalid = run("benchmarks/workloads-v3.json", {
      ...metadata,
      sourceCommit: "invalid",
    });
    expect(invalid.status).not.toBe(0);
    expect(invalid.stderr).toContain("Invalid source metadata");
    const mismatch = run("benchmarks/workloads-v3.json", metadata);
    expect(mismatch.status).not.toBe(0);
    expect(mismatch.stderr).toContain("Binary differs from source metadata");
    expect(existsSync(output)).toBe(false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
