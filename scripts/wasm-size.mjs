import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const header = Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]);
const sectionNames = ['custom', 'type', 'import', 'function', 'table', 'memory',
  'global', 'export', 'start', 'element', 'code', 'data', 'data-count', 'tag'];
const utf8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

/** Parse section framing, not instructions or full WebAssembly validity. */
export function wasmSections(input) {
  const bytes = Buffer.from(input);
  if (bytes.length < 8 || !bytes.subarray(0, 8).equals(header)) {
    throw new Error('Expected a WebAssembly binary with format version 1');
  }
  let offset = 8;
  const uint32 = limit => {
    let value = 0;
    for (let index = 0; index < 5; index++) {
      if (offset >= limit) throw new Error('Truncated unsigned LEB128');
      const byte = bytes[offset++];
      if (index === 4 && byte > 15) throw new Error('Unsigned LEB128 exceeds 32 bits');
      value += (byte & 127) * 2 ** (7 * index);
      if (!(byte & 128)) return value;
    }
    throw new Error('Unsigned LEB128 exceeds 32 bits');
  };
  const sections = [];
  while (offset < bytes.length) {
    const start = offset;
    const id = bytes[offset++];
    const payloadBytes = uint32(bytes.length);
    const payloadStart = offset;
    const end = payloadStart + payloadBytes;
    if (end > bytes.length) throw new Error('Section payload exceeds the module');
    let customName;
    if (id === 0) {
      const nameBytes = uint32(end);
      if (offset + nameBytes > end) throw new Error('Custom name exceeds its section');
      customName = utf8.decode(bytes.subarray(offset, offset + nameBytes));
    }
    sections.push({ id, name: id === 0 ? customName : sectionNames[id] ?? `section-${id}`,
      start, payloadStart, end, payloadBytes, totalBytes: end - start });
    offset = end;
  }
  return sections;
}

/** Keep every byte except complete custom sections whose name is exactly "name". */
export function stripWasmNames(input) {
  const bytes = Buffer.from(input);
  return Buffer.concat([bytes.subarray(0, 8), ...wasmSections(bytes)
    .filter(section => !(section.id === 0 && section.name === 'name'))
    .map(section => bytes.subarray(section.start, section.end))]);
}

const artifact = bytes => ({ rawBytes: bytes.length,
  gzipLevel9Bytes: gzipSync(bytes, { level: 9 }).length, sha256: sha256(bytes) });

export function inspectWasmSize(input) {
  const bytes = Buffer.from(input), sections = wasmSections(bytes);
  const stripped = stripWasmNames(bytes);
  const original = artifact(bytes), withoutNames = artifact(stripped);
  const core = Buffer.concat([bytes.subarray(0, 8), ...sections.filter(x => x.id !== 0)
    .map(x => bytes.subarray(x.start, x.end))]);
  return {
    version: 1,
    boundary: 'Section framing and exact bytes; full module validation and execution require separate checks. Gzip level 9 is computed, not deployed compression.',
    original, sections,
    nameStrippedCandidate: { ...withoutNames,
      removedSections: sections.filter(x => x.id === 0 && x.name === 'name').length,
      savedRawBytes: original.rawBytes - withoutNames.rawBytes,
      savedGzipLevel9Bytes: original.gzipLevel9Bytes - withoutNames.gzipLevel9Bytes },
    executableSectionsSHA256: sha256(core),
    candidateExecutableSectionsSHA256: sha256(Buffer.concat([stripped.subarray(0, 8),
      ...wasmSections(stripped).filter(x => x.id !== 0).map(x => stripped.subarray(x.start, x.end))])),
  };
}

export function writeNameStrippedArtifact(inputPath, outputPath, expectedInputSHA256) {
  if (resolve(inputPath) === resolve(outputPath)) throw new Error('Candidate must use a separate output path');
  const input = readFileSync(inputPath);
  if (expectedInputSHA256 && sha256(input) !== expectedInputSHA256) throw new Error('Input changed during inspection');
  const bytes = stripWasmNames(input);
  // Exclusive creation also protects existing symlinks and hardlinked archives.
  writeFileSync(outputPath, bytes, { flag: 'wx' });
  return bytes;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const positional = args.filter(x => !x.startsWith('--'));
  const options = args.filter(x => x.startsWith('--'));
  if (positional.length !== 1 || options.length > 1 || options.some(x => !x.startsWith('--strip-names=') || !x.slice(14))) {
    throw new Error('Usage: bun scripts/wasm-size.mjs artifact.wasm [--strip-names=new-candidate.wasm]');
  }
  const inputPath = resolve(positional[0]);
  const report = { inputPath, ...inspectWasmSize(readFileSync(inputPath)) };
  if (options.length) {
    const outputPath = resolve(options[0].slice(14));
    const output = writeNameStrippedArtifact(inputPath, outputPath, report.original.sha256);
    if (sha256(output) !== report.nameStrippedCandidate.sha256) throw new Error('Input changed during inspection');
    report.outputPath = outputPath;
  }
  console.log(JSON.stringify(report, null, 2));
}
