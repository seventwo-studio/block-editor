import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { arch, cpus, platform, release, totalmem } from "node:os";
import { dirname, resolve } from "node:path";
import { createInterface } from "node:readline";
import { performanceOptions, runPerformance } from "./performance.mjs";

const binary = resolve(process.argv[2] ?? ".build/release/editor-bridge");
const output = resolve(
  process.argv[3] ?? "test-results/performance/performance-native-v4.json",
);
const source = readFileSync(process.argv[4] ?? "benchmarks/workloads-v4.json");
const config = JSON.parse(source);
const options = performanceOptions(config, {
  profile: process.env.PERFORMANCE_PROFILE ?? "baseline",
  cases: process.env.PERFORMANCE_CASES?.split(",") ?? (process.env.PERFORMANCE_PROFILE === "smoke" ? ["ordinary-v4"] : undefined),
  repetitions:
    process.env.PERFORMANCE_REPETITIONS === undefined
      ? undefined
      : Number(process.env.PERFORMANCE_REPETITIONS),
  warmups:
    process.env.PERFORMANCE_WARMUPS === undefined
      ? undefined
      : Number(process.env.PERFORMANCE_WARMUPS),
});
if (options.cases.some((item) => item.version !== 4))
  throw new Error("V4 runner requires version 4 cases");
if (!process.argv[5]) throw new Error("V4 measurements require explicit pinned build provenance");
const metadata = JSON.parse(readFileSync(process.argv[5], "utf8"));
if (metadata === null || typeof metadata !== "object" || Array.isArray(metadata) ||
    typeof metadata.sourceCommit !== "string" || !/^[a-f0-9]{40}$/.test(metadata.sourceCommit) ||
    typeof metadata.sourceOverlayTree !== "string" || !/^[a-f0-9]{40}$/.test(metadata.sourceOverlayTree) ||
    typeof metadata.sourceDirty !== "boolean" ||
    typeof metadata.sourceBoundary !== "string" || !metadata.sourceBoundary.trim() ||
    !["debug", "release"].includes(metadata.artifactConfiguration) ||
    typeof metadata.artifactSHA256 !== "string" || !/^[a-f0-9]{64}$/.test(metadata.artifactSHA256))
  throw new Error("Invalid source metadata");
const artifactBytes = readFileSync(binary);
const artifactSHA256 = createHash("sha256").update(artifactBytes).digest("hex");
if (metadata.artifactSHA256 !== artifactSHA256)
  throw new Error("Binary differs from source metadata");
mkdirSync(dirname(output), { recursive: true });
const report = {
  version: 1,
  workloadHash: createHash("sha256").update(source).digest("hex"),
  options,
  sourceCommit: metadata.sourceCommit,
  sourceOverlayTree: metadata.sourceOverlayTree,
  sourceMetadata: metadata,
  sourceDirty: metadata.sourceDirty,
  sourceBoundary: metadata.sourceBoundary,
  numericBudgets: "unagreed",
  runtime: {
    name: "native",
    platform: platform(),
    architecture: arch(),
    osRelease: release(),
    cpu: cpus()[0]?.model,
    memoryBytes: totalmem(),
    hostRuntime: process.version,
    binary,
    boundary:
      "editor-bridge process; JSON serialization, pipes, response parsing and export identity assertions included; rendering/network excluded",
  },
  artifacts: [
    {
      name: "editor-bridge",
      rawBytes: statSync(binary).size,
      sha256: artifactSHA256,
      configuration: metadata.artifactConfiguration,
    },
  ],
  samples: [],
  complete: false,
};
const start = performance.now();
if (platform() !== "darwin") throw new Error("This memory runner requires macOS /usr/bin/time -l");
const child = spawn("/usr/bin/time", ["-l", binary], { stdio: ["pipe", "pipe", "pipe"] });
let resourceUsage = "";
child.stderr.setEncoding("utf8");
child.stderr.on("data", chunk => { resourceUsage += chunk; });
const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
const terminated = new Promise((resolve, reject) => {
  child.on("error", reject);
  child.on("exit", (code, signal) =>
    code === 0
      ? resolve()
      : reject(new Error(`Bridge exited ${code ?? signal}`)),
  );
});
terminated.catch(() => {});
const identities = new Map();
const call = async (input) => {
  if (input.command === "create") {
    input = {
      ...input,
      collaborationVersion: 4,
      epoch: "st94-v4-release-epoch",
    };
    identities.set(input.session, {
      documentID: input.documentID,
      actorID: input.actorID,
      epoch: input.epoch,
    });
  }
  if (input.command === "restore")
    identities.set(input.session, {
      documentID: input.snapshot.documentID,
      actorID: input.actorID,
      epoch: input.snapshot.epoch,
    });
  child.stdin.write(`${JSON.stringify(input)}\n`);
  const line = await lines.next();
  if (line.done) throw new Error("Bridge terminated before its response");
  const response = JSON.parse(line.value);
  if (response.ok && ["changes", "save", "syncState"].includes(input.command)) {
    const value = response.value,
      identity = identities.get(input.session);
    if (
      !identity ||
      value.version !== 4 ||
      value.epoch !== identity.epoch ||
      value.documentID !== identity.documentID
    )
      throw new Error("V4 export identity/epoch mismatch");
    if (
      input.command === "save" &&
      (!Array.isArray(value.localHistory?.undo) ||
        !Array.isArray(value.localHistory?.redo) ||
        value.localHistory.actorID !== identity.actorID)
    )
      throw new Error("V4 local history missing");
  }
  if (input.command === "close") identities.delete(input.session);
  return response;
};
const publish = () =>
  writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`);
// Invalidate any earlier successful output before starting this measurement.
publish();
let failure;
try {
  const response = await call({
    command: "create",
    session: "startup",
    actorID: "startup",
    documentID: "startup",
    blocks: [],
  });
  if (!response.ok) throw new Error(response.error);
  report.initialization = {
    freshProcessToFirstEmptySessionMs: performance.now() - start,
    diskCaches: "uncontrolled; not disk-cold startup",
  };
  await call({ command: "close", session: "startup" });
  await runPerformance(config, options, call, (sample) => {
    report.samples.push(sample);
    publish();
    console.log(
      `${sample.case} repeat ${sample.repetition}: edits p95 ${sample.metrics.offlineEdit.p95Ms.toFixed(2)} ms; rejoin ${sample.metrics.rejoin.totalMs.toFixed(2)} ms; snapshot ${sample.sizes.snapshotBytes} bytes`,
    );
  });
  report.complete = true;
} catch (error) {
  failure = error;
  report.error = String(error);
  report.complete = false;
} finally {
  child.stdin.end();
  try {
    await terminated;
  } catch (error) {
    failure ??= error;
    report.error = String(failure);
    report.complete = false;
  }
  writeFileSync(`${output}.resources.txt`, resourceUsage);
  const maximumRSS = resourceUsage.match(/(?:^|\n)\s*(\d+)\s+maximum resident set size/);
  if (!maximumRSS || !Number.isSafeInteger(Number(maximumRSS[1]))) {
    failure ??= new Error("Missing valid child resource usage");
    report.error = String(failure); report.complete = false;
  } else {
    report.memory = { maximumResidentSetSizeBytes: Number(maximumRSS[1]),
      method: "macOS /usr/bin/time -l for the editor-bridge child process",
      boundary: "Peak across this fresh child process, including retained benchmark sessions/history and JSON bridge buffers; rendering and parent runner excluded" };
  }
  publish();
}
if (failure) throw failure;
