import { dlopen, FFIType, CString } from "bun:ffi";
import { readFileSync, readdirSync, mkdirSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { createHash } from "node:crypto";
import { SwiftModernRecoveryError } from "../src/swift-modern.js";
import type { ModernTransport, ModernRecovery, ModernDocument } from "../src/swift-modern.js";
import { runModernAdapterContract } from "../tests/modern-adapter.contract.js";

const library = resolve(process.argv[2] ?? ".build/debug/libBlockEditorBridge.dylib");
const output = resolve(process.argv[3] ?? "test-results/modern-adapter/native.json");
const native = dlopen(library, {
  block_editor_alloc: { args: [FFIType.i32], returns: FFIType.ptr },
  block_editor_free: { args: [FFIType.ptr], returns: FFIType.void },
  block_editor_call: { args: [FFIType.ptr, FFIType.i32], returns: FFIType.ptr },
});
import { toArrayBuffer } from "bun:ffi";
let requests = 0;
const transport: ModernTransport = { call<T>(request: Record<string, unknown>): T {
  const bytes = new TextEncoder().encode(JSON.stringify(request)), input = native.symbols.block_editor_alloc(bytes.length);
  if (!input) throw new Error("Request allocation failed"); let result: ReturnType<typeof native.symbols.block_editor_call> = null;
  try {
    new Uint8Array(toArrayBuffer(input, 0, bytes.length)).set(bytes);
    result = native.symbols.block_editor_call(input, bytes.length); if (!result) throw new Error("No C ABI response"); requests++;
    const response = JSON.parse(new CString(result).toString()) as { ok: boolean; value: T; error?: string; recovery?: ModernRecovery };
    if (!response.ok) { if (response.error === "modernRecoveryRequired" && response.recovery) throw new SwiftModernRecoveryError(response.recovery); throw new Error(response.error); }
    return response.value;
  } finally { if (result) native.symbols.block_editor_free(result); native.symbols.block_editor_free(input); }
} };
const fixtureRoot = resolve("docs/acceptance/modern-editor/documents"), fixtureHashes: Record<string, string> = {};
const fixtures = readdirSync(fixtureRoot).filter(name => name.endsWith(".json")).flatMap(name => {
  const bytes = readFileSync(resolve(fixtureRoot, name)), document = JSON.parse(bytes.toString()) as ModernDocument;
  fixtureHashes[name] = createHash("sha256").update(bytes).digest("hex");
  return document.format === "seventwo.block-editor.document" ? [{ name, document }] : [];
});
try {
  const result = runModernAdapterContract(transport, fixtures);
  const report = { version: 1, transport: "native-C-ABI", librarySHA256: createHash("sha256").update(readFileSync(library)).digest("hex"), requests, ...result, fixtureHashes };
  mkdirSync(dirname(output), { recursive: true }); writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`); console.log(JSON.stringify({ requests, ...result }));
} finally { native.close(); }
