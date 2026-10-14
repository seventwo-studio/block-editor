// Reads an already registry-installed package in a separate consumer directory.
// No source checkout, local tarball, publication or credential operations.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const [host, output] = process.argv.slice(2);
assert.ok(host && output, 'Supply isolated consumer directory and receipt path');
assert.equal(dirname(fileURLToPath(import.meta.url)), resolve(host), 'Copy this verifier into the isolated installed host');
const require = createRequire(join(resolve(host), 'package.json'));
const name = '@seventwo-studio/block-editor-internal';
const entry = fileURLToPath(import.meta.resolve(name + '/swift'));
const root = dirname(dirname(entry));
const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
assert.equal(manifest.name, name); assert.equal(manifest.version, '0.2.0');
const provenance = JSON.parse(readFileSync(join(root, 'dist/modern-provenance.json'), 'utf8'));
assert.equal(provenance.sourceCommit, '1bb9a89c3f73c043588f8acabcde62c4e1b16be3');
assert.equal(provenance.packageVersion, '0.2.0');
assert.equal(provenance.protocolVersion, 7); assert.equal(provenance.documentFormatVersion, 1);
for (const [file, hash] of Object.entries(provenance.artifacts)) {
  assert.equal(createHash('sha256').update(readFileSync(join(root, file))).digest('hex'), hash);
}
const wasm = readFileSync(require.resolve(name + '/swift/modern.wasm'));
assert.equal(createHash('sha256').update(wasm).digest('hex'), '6f5febcfb962f735abde4bb8980aa175e568c64fd63c00404b83d512c73014fb');
const { SwiftEditorRuntime } = await import(import.meta.resolve(name + '/swift'));
await assert.rejects(() => SwiftEditorRuntime.initialize(Uint8Array.of(0, 97, 115, 109, 1, 0, 0, 0)), 'Missing shared ABI must reject explicitly');
const runtime = await SwiftEditorRuntime.initialize(wasm);
const ref = { type: 'entity-ref', entityType: 'note', entityId: 'original-reference', label: 'Doc', opaque: { keep: 1 } };
const document = {
  format: 'seventwo.block-editor.document', formatVersion: 1, documentID: 'clean-installed-columns',
  title: 'Installed 😀', appearance: { fontFamily: 'serif', fontSize: 'large', pageWidth: 'wide' },
  consumer: { retain: ['opaque', { rows: [{ id: 'not-an-editor-row' }] }] },
  blocks: [{ id: 'layout', type: 'columns', splitBasisPoints: 7000, opaque: 'layout', columns: [
    { id: 'left', opaque: 'left', children: [{ id: 'p', type: 'paragraph', content: [{ type: 'text', text: 'Left 😀' }, ref] }] },
    { id: 'right', opaque: 'right', children: [{ id: 'q', type: 'paragraph', content: [{ type: 'text', text: 'Right' }] }] }
  ] }]
};
const session = runtime.createModern({ documentID: document.documentID, actorID: 'installed', epoch: 'installed-epoch', document });
let reopened;
try {
  const node = session.node({ blockID: 'layout', path: ['columns', 'left', 'children', 'p'] });
  const field = session.field(node);
  assert.equal(session.text(field), 'Left 😀Doc');
  assert.equal(session.execute({ command: 'replaceText', target: session.captureTextRange(field, 7, 7), arguments: { text: '!' } }).status, 'applied');
  const expected = structuredClone(document);
  expected.blocks[0].columns[0].children[0].content[0].text = 'Left 😀!';
  assert.deepEqual(session.getSnapshot().document, expected);
  const saved = session.save();
  reopened = runtime.restoreModern(saved, 'installed');
  assert.deepEqual(reopened.getSnapshot().document, expected);
  assert.deepEqual(reopened.node({ blockID: 'layout', path: ['columns', 'left', 'children', 'p'] }), node);
  assert.equal(reopened.execute({ command: 'undo', arguments: {} }).status, 'applied');
  assert.deepEqual(reopened.getSnapshot().document, document);
  assert.equal(reopened.execute({ command: 'redo', arguments: {} }).status, 'applied');
  assert.deepEqual(reopened.getSnapshot().document, expected);
  writeFileSync(output, JSON.stringify({ passed: true, packageName: name, version: manifest.version,
    sourceCommit: provenance.sourceCommit, wasmSHA256: createHash('sha256').update(wasm).digest('hex'),
    checks: ['Installed provenance/artifact hashes', 'Explicit incompatible ABI rejection', 'Actual WASM initialization',
      'Unicode title/appearance and two ordered columns', 'Atomic reference and opaque metadata preservation',
      'Checked edit, save/reopen, stable identity and author Undo/Redo'],
    qualification: 'Node-hosted installed JS/WASM API smoke only; not native installation, UI/browser/assistive or performance acceptance.' }, null, 2) + '\n');
} finally { reopened?.close(); session.close(); }
