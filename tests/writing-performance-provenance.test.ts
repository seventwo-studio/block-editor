import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
// @ts-expect-error The shared verifier is plain ESM.
import { comparePerformanceReports } from "../scripts/compare-performance-reports.mjs";

// Verifier-only fixtures reuse archived timing shapes. These temporary files are
// deliberately relabelled test inputs, never evidence of another engine run.
const archived = JSON.parse(readFileSync("benchmarks/results/2026-10-01-v3-native-release/performance-native.json", "utf8"));
const workloadHash = createHash("sha256").update(readFileSync("benchmarks/workloads-writing.json")).digest("hex");
const revision = execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const tree = execFileSync("git", ["rev-parse", "HEAD^{tree}"], { encoding: "utf8" }).trim();

function fixtures(name: string) {
  const report = structuredClone(archived);
  report.sourceCommit = revision; report.sourceTree = tree; report.sourceDirty = false;
  report.workloadHash = workloadHash; report.numericBudgets = "unagreed";
  report.options.cases = report.options.cases.map((item: { name: string; version: number }) => ({ ...item, name: item.name.replace("v3", "v4"), version: 4 }));
  report.samples = report.samples.map((item: { case: string; version: number }) => ({ ...item, case: item.case.replace("v3", "v4"), version: 4 }));
  report.runtime = { name };
  const label = name === "native" ? "swift" : name.startsWith("wasm-") ? "wasm" : name;
  const roles: Record<string, string> = name === "native" ? { "editor-bridge": "release-bridge" } : name.startsWith("wasm-") ? { "block-editor.wasm": "wasm" } : { "libBlockEditorJNI.so": "jni", "libBlockEditorBridge.so": "swift-bridge", "libc++_shared.so": "cxx-runtime" };
  report.artifacts = Object.keys(roles).map((artifact, index) => ({ name: artifact, rawBytes: index + 100, sha256: String(index + 1).repeat(64) }));
  report.memory = { boundary: "Verifier fixture, no measured memory", maximumResidentSetSizeBytes: 1, maximumSampledProcessPssBytes: 1, linearMemoryHighWaterBytes: 65_536, samples: 1 };
  const provenance = { version: 1, runtime: label, source: { commit: revision, tree }, workflowRun: process.env.GITHUB_RUN_ID ?? "fixture", inputs: { "benchmarks/workloads-writing.json": workloadHash }, binaries: Object.fromEntries(report.artifacts.map((artifact: { name: string; rawBytes: number; sha256: string }) => [roles[artifact.name], { bytes: artifact.rawBytes, sha256: artifact.sha256 }])) };
  return { report, provenance, label };
}

for (const name of ["native", "android-api26-x86_64", "wasm-firefox"]) {
  test(`${name}: rejects substituted build artifacts and stale source/run provenance`, () => {
    const directory = mkdtempSync(join(tmpdir(), "writing-evidence-guards-"));
    const { report, provenance, label } = fixtures(name);
    const reportPath = join(directory, `performance-writing-${name}.json`);
    const provenancePath = join(directory, `runtime-provenance-${label}.json`);
    const save = (r = report, p = provenance) => { writeFileSync(reportPath, JSON.stringify(r)); writeFileSync(provenancePath, JSON.stringify(p)); };
    const verify = () => comparePerformanceReports(directory, [name], undefined, revision, true);
    try {
      save(); expect(verify()).toHaveLength(1);
      for (const mutate of [
        (r: typeof report) => { r.artifacts[0].sha256 = "f".repeat(64); },
        (r: typeof report) => { r.artifacts[0].rawBytes++; },
        (r: typeof report) => { r.artifacts.pop(); },
        (r: typeof report) => { r.artifacts.push(r.artifacts[0]); },
      ]) {
        const changed = structuredClone(report); mutate(changed); save(changed);
        expect(verify).toThrow(/artifact/);
      }
      for (const mutate of [
        (p: typeof provenance) => { p.source.commit = "f".repeat(40); },
        (p: typeof provenance) => { p.source.tree = "f".repeat(40); },
        (p: typeof provenance) => { p.inputs["benchmarks/workloads-writing.json"] = "f".repeat(64); },
        (p: typeof provenance) => { delete (p.binaries as Record<string, unknown>)[Object.keys(p.binaries)[0]]; },
      ]) {
        const changed = structuredClone(provenance); mutate(changed); save(report, changed);
        expect(verify).toThrow(/provenance|build/);
      }
      for (const mutate of [
        (r: typeof report) => { r.sourceDirty = true; },
        (r: typeof report) => { r.numericBudgets = "accepted"; },
        (r: typeof report) => { r.memory.maximumResidentSetSizeBytes = 0; r.memory.maximumSampledProcessPssBytes = 0; r.memory.linearMemoryHighWaterBytes = 0; },
      ]) {
        const changed = structuredClone(report); mutate(changed); save(changed);
        expect(verify).toThrow(/unqualified|memory/);
      }
      const wrongTree = structuredClone(report); wrongTree.sourceTree = "f".repeat(40); save(wrongTree);
      expect(verify).toThrow("tree differs");
      const originalRun = process.env.GITHUB_RUN_ID;
      try {
        process.env.GITHUB_RUN_ID = "guard-current-run";
        save(report, { ...provenance, workflowRun: "guard-old-run" });
        expect(verify).toThrow("wrong writing workflow run");
      } finally {
        if (originalRun === undefined) delete process.env.GITHUB_RUN_ID; else process.env.GITHUB_RUN_ID = originalRun;
      }
    } finally { rmSync(directory, { recursive: true, force: true }); }
  });
}
