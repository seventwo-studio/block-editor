// Review fixture only. This file reads supplied evidence; it performs no network,
// registry, permission, billing, repository, or publication operations.
import assert from 'node:assert/strict';

const publisher = 'seventwo-studio/block-editor-internal-packages';
const identity = '@seventwo-studio/block-editor-internal';
const exposedIdentity = '@seventwo-studio/block-editor';
const registry = 'https://npm.pkg.github.com';

export function checkPublicationBoundary(context, manifest, metadata) {
  assert.equal(context.repository.full_name, publisher, 'Wrong publisher');
  assert.equal(context.repository.private, true, 'Publisher must be private');
  assert.equal(context.repository.visibility, 'private', 'Internal is not private');
  assert.match(context.sourceSHA, /^[a-f0-9]{40}$/, 'Immutable source SHA required');
  assert.match(context.sourceTree, /^[a-f0-9]{40}$/, 'Source tree required');
  assert.equal(context.sourceVerified, true, 'Reviewed source must be GitHub Verified');
  assert.match(context.version, /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/, 'Exact version required');
  assert.equal(manifest.name, identity, 'Replacement identity required');
  assert.equal(manifest.version, context.version, 'Requested version differs');
  assert.equal(manifest.publishConfig?.registry, registry, 'Wrong registry');
  assert.equal(manifest.publishConfig?.access, undefined, 'Do not request public access');
  assert.equal(manifest.repository?.url, `git+https://github.com/${publisher}.git`, 'Package repository must be private publisher');
  if (metadata.status === 404) {
    assert.equal(context.firstPublication, true, '404 requires explicit reviewed first publication');
    return { phase: 'first-publication-candidate', identity, version: context.version };
  }
  assert.equal(metadata.status, 200, 'Unknown package metadata response');
  assert.equal(metadata.body?.name, 'block-editor-internal', 'Wrong package metadata');
  assert.equal(metadata.body?.visibility, 'private', 'Package must be private');
  assert.equal(metadata.body?.repository?.full_name, publisher, 'Wrong package association');
  return { phase: 'existing-private-candidate', identity, version: context.version };
}

export function checkConsumerLock(manifest, lock, installed, release) {
  assert.equal(manifest.packageManager, 'pnpm@11.25.0', 'Consumer toolchain changed');
  assert.equal(manifest.dependencies?.[identity], release.version, 'Consumer must pin exact version');
  assert.equal(String(lock.lockfileVersion), '9.0', 'Unreviewed lockfile format');
  for (const importer of Object.values(lock.importers ?? {})) {
    for (const field of ['dependencies', 'devDependencies', 'optionalDependencies']) {
      assert.equal(importer[field]?.[exposedIdentity], undefined, 'Exposed identity is not a consumer fallback');
    }
  }
  for (const field of ['dependencies', 'devDependencies', 'optionalDependencies']) {
    assert.equal(manifest[field]?.[exposedIdentity], undefined, 'Remove exposed identity');
  }
  const overrides = { ...manifest.pnpm?.overrides, ...lock.overrides };
  assert.ok(!Object.keys(overrides).some(key => key.includes('block-editor')), 'Editor overrides invalidate clean resolution');
  const locked = lock.importers?.['.']?.dependencies?.[identity];
  assert.equal(locked?.specifier, release.version, 'Lock specifier must be exact');
  assert.ok(locked?.version === release.version || locked?.version?.startsWith(`${release.version}(`), 'Lock resolves another source/version');
  const resolution = lock.packages?.[`${identity}@${release.version}`]?.resolution;
  assert.equal(resolution?.integrity, release.integrity, 'Locked integrity differs from accepted artifact');
  assert.match(release.integrity, /^sha512-[A-Za-z0-9+/]+={0,2}$/, 'SHA-512 integrity required');
  assert.equal(Buffer.from(release.integrity.slice(7), 'base64').length, 64, 'Malformed SHA-512 digest');
  const tarball = new URL(resolution?.tarball);
  assert.equal(tarball.origin, registry, 'Public/local tarball fallback is forbidden');
  assert.equal(tarball.username + tarball.password + tarball.search + tarball.hash, '', 'Tarball URL may not contain credentials or parameters');
  assert.equal(resolution.tarball, release.tarball, 'Tarball differs from accepted registry artifact');
  assert.equal(installed.name, identity, 'Installed identity differs');
  assert.equal(installed.version, release.version, 'Installed version differs');
  return { identity, version: release.version, integrity: release.integrity };
}
