import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { sourceInputs } from "./record-modern-build.mjs";

const manifest = JSON.parse(readFileSync("package.json", "utf8"));
if (manifest.version !== "0.2.0") throw new Error("Unexpected modern candidate version");
if (execFileSync("git", ["status", "--porcelain"], { encoding: "utf8" }).trim()) throw new Error("Freeze and commit the candidate before generating provenance");
const digest = bytes => createHash("sha256").update(bytes).digest("hex");
const sourceFiles = sourceInputs();
const sourceCommit = execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const builds = ["wasm", "javascript"].map(runtime => {
  const receipt = JSON.parse(readFileSync(`dist/modern-build-${runtime}.json`, "utf8"));
  if (!receipt.sourceClean || receipt.sourceCommit !== sourceCommit || JSON.stringify(receipt.sourceInputs) !== JSON.stringify(sourceFiles)) throw new Error(`Rebuild ${runtime} from the frozen candidate before recording provenance`);
  for (const [path, expected] of Object.entries(receipt.artifacts)) if (digest(readFileSync(path)) !== expected) throw new Error(`Stale ${runtime} artifact: ${path}`);
  return receipt;
});
const artifacts = {};
for (const entry of readdirSync("dist", { withFileTypes: true })) if (entry.isFile() && /\.(js|d\.ts|wasm)$/.test(entry.name)) artifacts[`dist/${entry.name}`] = digest(readFileSync(`dist/${entry.name}`));
for (const path of ["src/swift-modern.css", "docs/modern-editor-handoff.md"]) artifacts[path] = digest(readFileSync(path));
if (!artifacts["dist/block-editor.wasm"]) throw new Error("Build the actual matching WASM before preparing this candidate");
writeFileSync("dist/modern-provenance.json", JSON.stringify({ version: 1, packageName: manifest.name, packageVersion: manifest.version,
  documentFormatVersion: 1, protocolVersion: 7,
  sourceCommit: execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
  sourceTree: execFileSync("git", ["rev-parse", "HEAD^{tree}"], { encoding: "utf8" }).trim(),
  sourceFiles, builds, artifacts }, null, 2) + "\n");
