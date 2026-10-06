import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export const digest = bytes => createHash("sha256").update(bytes).digest("hex");
export function sourceInputs() {
  const files = {};
  function walk(directory) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) walk(path);
      else if (/\.(swift|ts|tsx|kt|css|c)$/.test(path)) files[path] = digest(readFileSync(path));
    }
  }
  for (const path of ["Sources", "src", "android/editor/src/main/java", "android/editor/src/main/cpp"]) walk(path);
  for (const path of ["Package.swift", "package.json", "tsconfig.build.json", "scripts/build-wasm.sh", "scripts/build-android.sh"]) files[path] = digest(readFileSync(path));
  return files;
}
if (process.argv[1]?.endsWith("record-modern-build.mjs")) {
  const runtime = process.argv[2];
  if (!["wasm", "javascript", "android"].includes(runtime)) throw new Error("Unknown build runtime");
  const artifacts = {};
  if (runtime === "android") {
    for (const abi of (process.env.ANDROID_ABIS ?? "arm64-v8a x86_64").split(/\s+/).filter(Boolean)) for (const name of ["libBlockEditorBridge.so", "libBlockEditorJNI.so", "libc++_shared.so"]) {
      const path = `android/editor/src/main/jniLibs/${abi}/${name}`; artifacts[path] = digest(readFileSync(path));
    }
  }
  for (const entry of readdirSync("dist", { withFileTypes: true })) {
    if (entry.isFile() && (runtime === "wasm" ? entry.name === "block-editor.wasm" : runtime === "javascript" && /\.(js|d\.ts)$/.test(entry.name))) artifacts[`dist/${entry.name}`] = digest(readFileSync(`dist/${entry.name}`));
  }
  if (!Object.keys(artifacts).length) throw new Error("No built artifacts");
  writeFileSync(`dist/modern-build-${runtime}.json`, JSON.stringify({ version: 1, runtime,
    sourceCommit: execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
    sourceClean: !execFileSync("git", ["status", "--porcelain"], { encoding: "utf8" }).trim(),
    sourceInputs: sourceInputs(), artifacts,
    compiler: runtime !== "javascript" ? execFileSync(process.env.SWIFT_BIN ?? "swift", ["--version"], { encoding: "utf8" }).trim() : execFileSync(process.execPath, ["node_modules/typescript/bin/tsc", "--version"], { encoding: "utf8" }).trim(),
  }, null, 2) + "\n");
}
