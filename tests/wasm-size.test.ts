import { test, expect } from 'bun:test';
import { mkdtempSync, writeFileSync, readFileSync, linkSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error The artifact inspector is plain ESM.
import { wasmSections, stripWasmNames, inspectWasmSize, writeNameStrippedArtifact } from '../scripts/wasm-size.mjs';

const header = Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]);
const section = (id: number, data: number[]) => Buffer.from([id, data.length, ...data]);
const custom = (name: string, data: number[] = []) => {
  const bytes = Buffer.from(name);
  return section(0, [bytes.length, ...bytes, ...data]);
};

test('removes only name metadata and preserves exact executable and other custom sections', () => {
  // A valid empty-function module with an export and harmless custom metadata.
  const parts = [section(1, [1, 0x60, 0, 0]), custom('name', [1, 0]),
    section(3, [1, 0]), custom('λ'), section(7, [1, 1, 102, 0, 0]),
    section(10, [1, 2, 0, 0x0b]), custom('producers'), custom('target_features'),
    custom('\uFEFFname'), custom('name\0')];
  const original = Buffer.concat([header, ...parts]);
  const stripped = stripWasmNames(original);
  expect(WebAssembly.validate(original)).toBe(true);
  expect(WebAssembly.validate(stripped)).toBe(true);
  expect(new WebAssembly.Instance(new WebAssembly.Module(stripped)).exports.f).toBeFunction();
  expect(stripped).toEqual(Buffer.concat([header, ...parts.filter((_, i) => i !== 1)]));
  const report = inspectWasmSize(original);
  expect(report.sections.reduce((n: number, x: { totalBytes: number }) => n + x.totalBytes, 8)).toBe(original.length);
  expect(report.executableSectionsSHA256).toBe(report.candidateExecutableSectionsSHA256);
  expect(report.nameStrippedCandidate.savedRawBytes).toBe(parts[1].length);
  expect(stripWasmNames(stripped)).toEqual(stripped);
});

test('accepts bounded nonminimal unsigned LEB128 and repeated custom sections', () => {
  const bytes = Buffer.concat([header, Buffer.from([0, 0x82, 0, 1, 110]), custom('name'), custom('name')]);
  expect(wasmSections(bytes)).toHaveLength(3);
  expect(stripWasmNames(bytes)).toEqual(Buffer.concat([header, Buffer.from([0, 0x82, 0, 1, 110])]));
});

test('rejects wrong headers, overflowing lengths and truncated or invalid custom names', () => {
  const malformed = [header.subarray(0, 7), Buffer.from([0, 97, 115, 109, 2, 0, 0, 0]),
    Buffer.concat([header, Buffer.from([1])]),
    Buffer.concat([header, Buffer.from([1, 0x80])]),
    Buffer.concat([header, Buffer.from([1, 0xff, 0xff, 0xff, 0xff, 0x10])]),
    Buffer.concat([header, Buffer.from([1, 0x80, 0x80, 0x80, 0x80, 0x80, 0])]),
    Buffer.concat([header, section(1, [0]).subarray(0, 2)]),
    Buffer.concat([header, section(0, [])]),
    Buffer.concat([header, section(0, [2, 97])]),
    Buffer.concat([header, section(0, [1, 0xff])])];
  for (const bytes of malformed) expect(() => stripWasmNames(bytes)).toThrow();
});

test('creates a separate candidate and refuses source, existing files, hardlinks and symlinks', () => {
  const root = mkdtempSync(join(tmpdir(), 'editor-wasm-size-'));
  try {
    const source = join(root, 'source.wasm'), output = join(root, 'candidate.wasm');
    const bytes = Buffer.concat([header, custom('name')]);
    writeFileSync(source, bytes);
    expect(() => writeNameStrippedArtifact(source, output, 'wrong-input-hash')).toThrow('Input changed');
    writeNameStrippedArtifact(source, output);
    expect(readFileSync(output)).toEqual(header);
    expect(readFileSync(source)).toEqual(bytes);
    expect(() => writeNameStrippedArtifact(source, source)).toThrow('separate output');
    expect(() => writeNameStrippedArtifact(source, output)).toThrow();
    for (const kind of ['hardlink', 'symlink']) {
      const path = join(root, kind);
      if (kind === 'hardlink') linkSync(source, path); else symlinkSync(source, path);
      expect(() => writeNameStrippedArtifact(source, path)).toThrow();
      expect(readFileSync(source)).toEqual(bytes);
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});
