// Local staging only. No repository, registry, credential, grant or billing writes.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve, sep } from 'node:path';
import { tmpdir } from 'node:os';

const [destination, reviewedCommit] = process.argv.slice(2);
assert.ok(destination && isAbsolute(destination), 'Supply a new absolute output directory');
assert.match(reviewedCommit ?? '', /^[a-f0-9]{40}$/, 'Supply the exact reviewed source commit');
assert.equal(execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(), reviewedCommit);
assert.equal(execFileSync('git', ['status', '--porcelain'], { encoding: 'utf8' }).trim(), '', 'Commit the candidate first');
assert.ok(!existsSync(destination), 'Never replace an existing candidate');
execFileSync(process.execPath, ['scripts/modern-package-provenance.mjs'], { stdio: 'inherit' });
const manifest = JSON.parse(readFileSync('package.json', 'utf8'));
assert.equal(manifest.name, '@seventwo-studio/block-editor'); assert.equal(manifest.version, '0.2.0');
const provenance = JSON.parse(readFileSync('dist/modern-provenance.json', 'utf8'));
assert.equal(provenance.sourceCommit, reviewedCommit);
const originalManifest = readFileSync('package.json');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const temporary = mkdtempSync(join(tmpdir(), 'modern-private-source-pack-'));
try {
  const [original] = JSON.parse(execFileSync('npm', ['pack', '--json', '--ignore-scripts', '--pack-destination', temporary], { encoding: 'utf8' }));
  mkdirSync(destination, { mode: 0o700 });
  const staging = join(destination, 'package'); mkdirSync(staging, { mode: 0o700 });
  // Copy only npm's admitted package inventory; never copy credentials, source
  // working directories or an arbitrary archive path into the private artifact.
  for (const file of original.files) {
    const source = resolve(file.path), target = resolve(staging, file.path);
    assert.ok(source.startsWith(process.cwd() + sep) && target.startsWith(staging + sep));
    mkdirSync(dirname(target), { recursive: true }); copyFileSync(source, target);
  }
  manifest.name = '@seventwo-studio/block-editor-internal';
  manifest.repository.url = 'git+https://github.com/seventwo-studio/block-editor-internal-packages.git';
  const privateManifest = JSON.stringify(manifest, null, 2) + '\n';
  writeFileSync(join(staging, 'package.json'), privateManifest);
  provenance.packageName = manifest.name;
  provenance.distribution = { proposal: true, publisher: 'seventwo-studio/block-editor-internal-packages',
    sourcePackageName: '@seventwo-studio/block-editor', originalManifestSHA256: hash(originalManifest), candidateManifestSHA256: hash(privateManifest) };
  writeFileSync(join(staging, 'dist/modern-provenance.json'), JSON.stringify(provenance, null, 2) + '\n');
  execFileSync(process.execPath, [resolve('scripts/check-package.mjs')], { cwd: staging, stdio: 'inherit' });
  const [packed] = JSON.parse(execFileSync('npm', ['pack', '--json', '--ignore-scripts', '--pack-destination', destination], { cwd: staging, encoding: 'utf8' }));
  const receipt = { proposal: true, published: false, name: packed.name, version: packed.version, sourceCommit: reviewedCommit,
    sourceTree: provenance.sourceTree, publisher: provenance.distribution.publisher, integrity: packed.integrity,
    tarballSHA256: hash(readFileSync(join(destination, packed.filename))), packedBytes: packed.size, unpackedBytes: packed.unpackedSize,
    artifactHashes: provenance.artifacts, manifest: provenance.distribution };
  writeFileSync(join(destination, 'private-candidate.json'), JSON.stringify(receipt, null, 2) + '\n');
  console.log(JSON.stringify({ name: receipt.name, version: receipt.version, sourceCommit: reviewedCommit, integrity: receipt.integrity, published: false }));
} finally { rmSync(temporary, { recursive: true, force: true }); }
