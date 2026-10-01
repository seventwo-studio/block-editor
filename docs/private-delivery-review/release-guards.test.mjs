import assert from 'node:assert/strict';
import test from 'node:test';
import { checkConsumerLock, checkPublicationBoundary } from './release-guards.mjs';

const publisher = 'seventwo-studio/block-editor-internal-packages';
const identity = '@seventwo-studio/block-editor-internal';
function publication() {
  return {
    context: { repository: { full_name: publisher, private: true, visibility: 'private' }, sourceSHA: 'a'.repeat(40), sourceTree: 'b'.repeat(40), sourceVerified: true, version: '0.1.0', firstPublication: false },
    manifest: { name: identity, version: '0.1.0', publishConfig: { registry: 'https://npm.pkg.github.com' }, repository: { url: `git+https://github.com/${publisher}.git` } },
    metadata: { status: 200, body: { name: 'block-editor-internal', visibility: 'private', repository: { full_name: publisher } } },
  };
}
function consumer() {
  const integrity = `sha512-${Buffer.alloc(64, 7).toString('base64')}`;
  const tarball = 'https://npm.pkg.github.com/download/@seventwo-studio/block-editor-internal/0.1.0/example';
  return {
    manifest: { packageManager: 'pnpm@11.25.0', dependencies: { [identity]: '0.1.0' } },
    lock: { lockfileVersion: '9.0', importers: { '.': { dependencies: { [identity]: { specifier: '0.1.0', version: '0.1.0(react@19.3.0)' } } } }, packages: { [`${identity}@0.1.0`]: { resolution: { integrity, tarball } } } },
    installed: { name: identity, version: '0.1.0' },
    release: { version: '0.1.0', integrity, tarball },
  };
}
const checkPublication = f => checkPublicationBoundary(f.context, f.manifest, f.metadata);
const checkConsumer = f => checkConsumerLock(f.manifest, f.lock, f.installed, f.release);

test('private existing publication passes fixture validation', () => assert.equal(checkPublication(publication()).phase, 'existing-private-candidate'));
test('404 passes only a private publisher with explicit first-publication context', () => {
  const f = publication(); f.metadata = { status: 404 };
  assert.throws(() => checkPublication(f));
  f.context.firstPublication = true;
  assert.equal(checkPublication(f).phase, 'first-publication-candidate');
  f.context.repository.private = false;
  assert.throws(() => checkPublication(f));
});
for (const [name, mutate] of [
  ['public source publisher', f => { f.context.repository.full_name = 'seventwo-studio/block-editor'; }],
  ['internal publisher', f => { f.context.repository.visibility = 'internal'; }],
  ['public package', f => { f.metadata.body.visibility = 'public'; }],
  ['internal package', f => { f.metadata.body.visibility = 'internal'; }],
  ['wrong repository association', f => { f.metadata.body.repository.full_name = 'seventwo-studio/block-editor'; }],
  ['old npm identity', f => { f.manifest.name = '@seventwo-studio/block-editor'; }],
  ['public manifest inheritance', f => { f.manifest.repository.url = 'git+https://github.com/seventwo-studio/block-editor.git'; }],
  ['unsigned source', f => { f.context.sourceVerified = false; }],
  ['mutable source ref', f => { f.context.sourceSHA = 'main'; }],
  ['version mismatch', f => { f.manifest.version = '0.2.0'; }],
  ...[401, 403, 429, 500].map(status => [`metadata HTTP ${status}`, f => { f.metadata.status = status; }]),
]) test(`reject ${name}`, () => { const f = publication(); mutate(f); assert.throws(() => checkPublication(f)); });

test('exact private consumer artifact with peer suffix passes fixture validation', () => assert.equal(checkConsumer(consumer()).version, '0.1.0'));
for (const [name, mutate] of [
  ['floating dependency', f => { f.manifest.dependencies[identity] = '^0.1.0'; }],
  ['workspace resolution', f => { f.lock.importers['.'].dependencies[identity].version = 'link:../block-editor'; }],
  ['local manifest', f => { f.manifest.dependencies[identity] = 'file:editor.tgz'; }],
  ['public tarball', f => { f.lock.packages[`${identity}@0.1.0`].resolution.tarball = 'https://registry.npmjs.org/editor.tgz'; }],
  ['missing tarball origin', f => { delete f.lock.packages[`${identity}@0.1.0`].resolution.tarball; }],
  ['changed integrity', f => { f.lock.packages[`${identity}@0.1.0`].resolution.integrity = 'sha512-bad'; }],
  ['credential in tarball', f => { f.release.tarball = f.lock.packages[`${identity}@0.1.0`].resolution.tarball = 'https://token@npm.pkg.github.com/editor.tgz'; }],
  ['exposed identity', f => { f.lock.importers['.'].dependencies['@seventwo-studio/block-editor'] = { version: '0.1.0' }; }],
  ['override', f => { f.manifest.pnpm = { overrides: { [identity]: 'file:editor.tgz' } }; }],
  ['wrong installed version', f => { f.installed.version = '0.2.0'; }],
]) test(`reject consumer ${name}`, () => { const f = consumer(); mutate(f); assert.throws(() => checkConsumer(f)); });
