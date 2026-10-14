// Local proposal preparation. Never deploys, tags, grants access or publishes.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join } from 'node:path';
import { sameSourceInputs, sourceInputs } from './record-modern-build.mjs';

const [destination, sourceCommit, version, mavenStage] = process.argv.slice(2);
assert(destination && isAbsolute(destination) && !existsSync(destination), 'Use a fresh absolute destination');
assert.match(sourceCommit ?? '', /^[a-f0-9]{40}$/);
assert.match(version ?? '', /^\d+\.\d+\.\d+$/); assert.notEqual(version, '0.2.0', 'Private 0.2.0 is immutable');
assert(mavenStage && isAbsolute(mavenStage), 'Supply the generated local Maven staging directory');
assert.equal(execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(), sourceCommit);
assert.equal(execFileSync('git', ['status', '--porcelain'], { encoding: 'utf8' }).trim(), '', 'Commit preparation code first');
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const inputs = sourceInputs();
const builds = ['javascript', 'wasm', 'android'].map(runtime => {
  const receipt = JSON.parse(readFileSync(`dist/modern-build-${runtime}.json`, 'utf8'));
  assert(receipt.sourceClean && receipt.sourceCommit === sourceCommit && sameSourceInputs(receipt.sourceInputs, inputs), `Rebuild ${runtime} from this clean source`);
  for (const [file, hash] of Object.entries(receipt.artifacts)) assert.equal(digest(readFileSync(file)), hash, file);
  return receipt;
});
mkdirSync(destination, { mode: 0o700 });
const files = {};
function copy(source, relative) {
  const target = join(destination, relative); mkdirSync(dirname(target), { recursive: true }); copyFileSync(source, target);
  files[relative] = digest(readFileSync(target));
}
// Git's tracked allowlist excludes credentials, local memory and build caches.
const tracked = execFileSync('git', ['ls-files', '-z', 'Package.swift', 'Sources', 'Examples', 'tests', 'docs/acceptance', 'benchmarks', 'LICENSE'], { encoding: 'utf8' }).split('\0').filter(Boolean);
for (const file of tracked) {
  assert(!file.split('/').some(part => part === '..' || part.startsWith('.')), `Unexpected source path ${file}`);
    assert(lstatSync(file).isFile() && !lstatSync(file).isSymbolicLink(), `Unsupported source entry ${file}`);
  copy(file, `swift-package/${file}`);
}
const coordinate = `studio.seventwo:block-editor:${version}`;
const directory = join(mavenStage, 'studio', 'seventwo', 'block-editor', version);
const prefix = `block-editor-${version}`;
for (const suffix of ['.aar', '.pom', '.module', '-sources.jar']) {
  const file = prefix + suffix; assert(existsSync(join(directory, file)), `Missing ${file}`); copy(join(directory, file), `maven/studio/seventwo/block-editor/${version}/${file}`);
}
const pom = readFileSync(join(directory, prefix + '.pom'), 'utf8');
assert(pom.includes('<packaging>aar</packaging>') && pom.includes('<version>' + version + '</version>'));
for (const dependency of ['compose-bom', 'foundation', 'material3']) assert(pom.includes(`<artifactId>${dependency}</artifactId>`), `Missing dependency ${dependency}`);
const module = JSON.parse(readFileSync(join(directory, prefix + '.module'), 'utf8'));
assert.equal(module.component.version, version);
for (const usage of ['java-api', 'java-runtime']) assert(module.variants.some(value =>
  value.attributes['org.gradle.usage'] === usage && value.attributes['org.gradle.category'] === 'library'), `Missing ${usage} library variant`);
const native = builds.find(value => value.runtime === 'android').artifacts;
for (const abi of ['arm64-v8a', 'x86_64']) for (const name of ['libBlockEditorBridge.so', 'libBlockEditorJNI.so', 'libc++_shared.so']) {
  const entry = `jni/${abi}/${name}`;
  const bytes = execFileSync('unzip', ['-p', join(directory, prefix + '.aar'), entry], { maxBuffer: 128 * 1024 * 1024 });
  assert.equal(digest(bytes), native[`android/editor/src/main/jniLibs/${abi}/${name}`], entry);
}
const receipt = { proposal: true, published: false, deploymentAuthorized: false, verifiedSourceRequiredBeforePublication: true,
  sourceCommit, sourceTree: execFileSync('git', ['rev-parse', 'HEAD^{tree}'], { encoding: 'utf8' }).trim(),
  sourcePackageVersion: JSON.parse(readFileSync('package.json', 'utf8')).version, candidateVersion: version,
  publisher: 'seventwo-studio/block-editor-internal-packages', swift: { proposedGitTag: version, root: 'swift-package' },
  kotlin: { coordinate, repository: 'https://maven.pkg.github.com/seventwo-studio/block-editor-internal-packages', abis: ['arm64-v8a', 'x86_64'] },
  sourceInputs: inputs, buildReceipts: builds, files, gates: ['Unused version and exact reviewed GitHub Verified source', 'Current CI/review and concrete remote deployment/publication approval', 'Explicit private Git/Maven reader authorization', 'Actual fresh-cache published consumers for all three runtimes', 'Matching JavaScript/WASM candidate; immutable 0.2.0 is not this source'] };
writeFileSync(join(destination, 'native-candidate.json'), JSON.stringify(receipt, null, 2) + '\n');
console.log(JSON.stringify({ proposal: true, published: false, sourceCommit, version, coordinate, files: Object.keys(files).length }));
