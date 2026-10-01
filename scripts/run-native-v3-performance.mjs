import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { arch, cpus, platform, release, totalmem } from "node:os";
import { dirname, resolve } from "node:path";
import { createInterface } from "node:readline";
import { performanceOptions, runPerformance } from "./performance.mjs";

const binary = resolve(process.argv[2] ?? ".build/release/editor-bridge");
const output = resolve(
  process.argv[3] ?? "test-results/performance/performance-native-v3.json",
);
const source = readFileSync(process.argv[4] ?? "benchmarks/workloads-v3.json");
const config = JSON.parse(source);
const options = performanceOptions(config, {
  profile: process.env.PERFORMANCE_PROFILE ?? "baseline",
  cases: process.env.PERFORMANCE_CASES?.split(","),
  repetitions:
    process.env.PERFORMANCE_REPETITIONS === undefined
      ? undefined
      : Number(process.env.PERFORMANCE_REPETITIONS),
  warmups:
    process.env.PERFORMANCE_WARMUPS === undefined
      ? undefined
      : Number(process.env.PERFORMANCE_WARMUPS),
});
if (options.cases.some((item) => item.version !== 3))
  throw new Error("V3 runner requires version 3 cases");
const metadata = process.argv[5]
  ? JSON.parse(readFileSync(process.argv[5], "utf8"))
  : null;
if (
  metadata &&
  (!/^[a-f0-9]{40}$/.test(metadata.sourceCommit) ||
    (metadata.sourceOverlayTree &&
      !/^[a-f0-9]{40}$/.test(metadata.sourceOverlayTree)) ||
    typeof metadata.sourceDirty !== "boolean")
)
  throw new Error("Invalid source metadata");
const artifactBytes = readFileSync(binary);
const artifactSHA256 = createHash("sha256").update(artifactBytes).digest("hex");
if (metadata?.artifactSHA256 && metadata.artifactSHA256 !== artifactSHA256)
  throw new Error("Binary differs from source metadata");
mkdirSync(dirname(output), { recursive: true });
const report = {
  version: 1,
  workloadHash: createHash("sha256").update(source).digest("hex"),
  options,
  sourceCommit:
    metadata?.sourceCommit ??
    execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
  sourceOverlayTree: metadata?.sourceOverlayTree,
  sourceMetadata: metadata,
  sourceDirty:
    metadata?.sourceDirty ??
    execFileSync("git", ["status", "--porcelain"], { encoding: "utf8" }).trim()
      .length > 0,
  sourceBoundary:
    metadata?.sourceBoundary ??
    "Invoking checkout; caller-supplied binary requires separate build provenance",
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
      configuration:
        "caller-supplied binary; use release build for baseline measurements",
    },
  ],
  samples: [],
  complete: false,
};
const start = performance.now();
const child = spawn(binary, [], { stdio: ["pipe", "pipe", "inherit"] });
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
      collaborationVersion: 3,
      epoch: "st94-v3-release-epoch",
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
      value.version !== 3 ||
      value.epoch !== identity.epoch ||
      value.documentID !== identity.documentID
    )
      throw new Error("V3 export identity/epoch mismatch");
    if (
      input.command === "save" &&
      (!Array.isArray(value.localHistory?.undo) ||
        !Array.isArray(value.localHistory?.redo) ||
        value.localHistory.actorID !== identity.actorID)
    )
      throw new Error("V3 local history missing");
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
  publish();
}
if (failure) throw failure;
