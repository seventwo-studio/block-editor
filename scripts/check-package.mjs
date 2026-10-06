import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const manifest = JSON.parse(readFileSync('package.json', 'utf8'));
assert.equal(manifest.publishConfig.registry, 'https://npm.pkg.github.com');
assert.equal(manifest.publishConfig.access, undefined);
const fixture = mkdtempSync(join(tmpdir(), 'block-editor-package-'));
try {
  const [packed] = JSON.parse(execFileSync('npm', ['pack', '--json', '--ignore-scripts', '--pack-destination', fixture], { encoding: 'utf8' }));
  const files = new Set(packed.files.map(file => file.path));
  for (const entry of Object.values(manifest.exports)) {
    for (const path of typeof entry === 'string' ? [entry] : Object.values(entry)) assert.ok(files.has(path.replace(/^\.\//, '')), `Missing export: ${path}`);
  }
  assert.ok(!packed.files.some(file => /(?:^|\/)(?:\.npmrc|\.env|node_modules|demo|scripts)(?:\/|$)/.test(file.path)));
  assert.ok(files.has('dist/block-editor.wasm'), 'Modern delivery requires its matching WASM');
  const provenance = JSON.parse(readFileSync('dist/modern-provenance.json', 'utf8'));
  assert.equal(provenance.packageVersion, manifest.version);
  assert.equal(provenance.protocolVersion, 7);
  assert.equal(provenance.documentFormatVersion, 1);
  assert.match(provenance.sourceCommit, /^[a-f0-9]{40}$/);
  for (const [path, expected] of Object.entries(provenance.artifacts)) {
    assert.ok(files.has(path), `Missing versioned artifact: ${path}`);
    assert.equal(createHash('sha256').update(readFileSync(path)).digest('hex'), expected, `Artifact mismatch: ${path}`);
  }
  writeFileSync(join(fixture, 'package.json'), JSON.stringify({ private: true, type: 'module' }));
  execFileSync('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund', '--package-lock=false', '--prefix', fixture, join(fixture, packed.filename)], { stdio: 'pipe' });
  writeFileSync(join(fixture, 'verify.mjs'), `
    import assert from 'node:assert/strict';
    import { readFileSync } from 'node:fs';
    import { makeBlock } from '@seventwo-studio/block-editor';
    import * as model from '@seventwo-studio/block-editor/model';
    import * as crdt from '@seventwo-studio/block-editor/crdt';
    import { Content } from '@seventwo-studio/block-editor/schema';
    import { BlockEditor } from '@seventwo-studio/block-editor/react';
    import { SwiftEditorRuntime, SwiftModernSession, SwiftModernCutover, SwiftModernRecoveryError } from '@seventwo-studio/block-editor/swift';
    import { SwiftModernBlockEditor, SwiftModernEditorSurface } from '@seventwo-studio/block-editor/swift/modern/react';
    import { ModernBrowserHost, ModernBrowserStore } from '@seventwo-studio/block-editor/swift/modern/host';
    import { SwiftBlockEditor } from '@seventwo-studio/block-editor/swift/react';
    import { createElement } from 'react';
    import { renderToStaticMarkup } from 'react-dom/server';
    const blocks = [makeBlock('paragraph')];
    assert.equal(Content.parse(blocks)[0].type, 'paragraph');
    assert.ok(Object.keys(model).length && Object.keys(crdt).length);
    assert.equal(typeof BlockEditor, 'function');
    assert.equal(typeof SwiftEditorRuntime.initialize, 'function');
    assert.equal(typeof SwiftModernSession.create, 'function');
    assert.equal(typeof SwiftModernCutover, 'function');
    assert.equal(typeof SwiftModernRecoveryError, 'function');
    assert.equal(typeof SwiftBlockEditor, 'function');
    assert.equal(typeof SwiftModernBlockEditor, 'function');
    assert.equal(typeof SwiftModernEditorSurface, 'function');
    assert.equal(typeof ModernBrowserHost, 'function');
    assert.equal(typeof ModernBrowserStore, 'function');
    assert.ok(renderToStaticMarkup(createElement(BlockEditor, { value: blocks, onChange() {}, allowMarkdown: false })).length > 0);
    assert.ok(readFileSync(new URL(import.meta.resolve('@seventwo-studio/block-editor/react.css')), 'utf8').length > 0);
  `);
  execFileSync(process.execPath, [join(fixture, 'verify.mjs')], { stdio: 'inherit' });
  console.log(JSON.stringify({ name: packed.name, version: packed.version, packedBytes: packed.size, unpackedBytes: packed.unpackedSize, integrity: packed.integrity }));
} finally {
  rmSync(fixture, { recursive: true, force: true });
}
