import { readFileSync, readdirSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { canonical } from './compatibility.mjs';
import { validateResourceSpec } from './writing-resource.mjs';
const root = resolve(process.argv[2] ?? 'test-results/runtime-reports');
const source = readFileSync('benchmarks/resources-writing.json'), spec = JSON.parse(source); validateResourceSpec(spec);
const specHash = createHash('sha256').update(source).digest('hex');
const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
if (git('status', '--porcelain', '--untracked-files=all')) throw new Error('Resource parity requires a clean exact source');
const expectedSource = { commit: git('rev-parse', 'HEAD'), tree: git('rev-parse', 'HEAD^{tree}'), dirty: false };
const files = path => readdirSync(path, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? files(join(path, entry.name)) : [join(path, entry.name)]);
const paths = files(root), runtimes = ['native', 'android-api26-x86_64', 'android-api35-x86_64', 'android-api35-arm64-v8a', 'wasm-chromium', 'wasm-webkit', 'wasm-firefox'];
function singleton(suffix) { const candidates = paths.filter(path => path.endsWith(`/${suffix}`)); if (candidates.length !== 1) throw new Error(`Expected exactly one ${suffix}, got ${candidates.length}`); return JSON.parse(readFileSync(candidates[0], 'utf8')); }
const previousAndroidPID = new Map();
const equal = (actual, expected, label) => { if (!isDeepStrictEqual(canonical(actual), canonical(expected))) throw new Error(`Resource evidence differs: ${label}`); };
for (const version of spec.protocols) for (const caseName of spec.cases) {
  let nativeProof;
  for (const runtime of runtimes) {
    const report = singleton(`resource-writing-${runtime}-v${version}-${caseName}.json`);
    if (report.version !== 1 || report.kind !== 'compact-production-resource-proof' || report.runtime !== runtime || report.protocol !== version || report.case !== caseName || report.complete !== true || report.error) throw new Error(`Incomplete resource proof: ${runtime}v${version}/${caseName}`);
    if (runtime.startsWith('android-')) {
      if (!Number.isSafeInteger(report.processPID) || report.processPID <= 0 || previousAndroidPID.get(runtime) === report.processPID) throw new Error('Resource JNI case lacks distinct actual process proof');
      previousAndroidPID.set(runtime, report.processPID);
    }
    equal(report.source, expectedSource, 'current source/tree'); equal(report.specSHA256, specHash, 'spec');
    const label = runtime === 'native' ? 'swift' : runtime.startsWith('wasm-') ? 'wasm' : runtime;
    const provenance = singleton(`runtime-provenance-${label}.json`);
    if (provenance.version !== 1 || provenance.runtime !== label) throw new Error('Invalid resource build manifest');
    equal(provenance.source, { commit: expectedSource.commit, tree: expectedSource.tree }, 'build source'); equal(provenance.inputs?.['benchmarks/resources-writing.json'], specHash, 'recorded spec input');
    if (process.env.GITHUB_RUN_ID && provenance.workflowRun !== process.env.GITHUB_RUN_ID) throw new Error('Resource proof from another workflow');
    const roles = runtime === 'native' ? { 'editor-bridge': 'debug-bridge' } : runtime.startsWith('wasm-') ? { 'block-editor.wasm': 'wasm' } : { 'libBlockEditorJNI.so': 'jni', 'libBlockEditorBridge.so': 'swift-bridge', 'libc++_shared.so': 'cxx-runtime' };
    if (!Array.isArray(report.artifacts) || report.artifacts.length !== Object.keys(roles).length || new Set(report.artifacts.map(x => x.name)).size !== report.artifacts.length) throw new Error('Incomplete resource artifact roles');
    for (const [name, role] of Object.entries(roles)) {
      const artifact = report.artifacts.find(x => x.name === name), binary = provenance.binaries?.[role];
      if (!artifact || artifact.role !== role || !binary || !Number.isSafeInteger(artifact.rawBytes) || artifact.rawBytes <= 0 || !/^[a-f0-9]{64}$/.test(artifact.sha256) || artifact.rawBytes !== binary.bytes || artifact.sha256 !== binary.sha256) throw new Error('Resource artifact differs from exact build');
    }
    const proof = report.proof;
    if (proof?.case !== caseName || proof.version !== version || typeof report.boundary !== 'string' || !report.boundary) throw new Error('Missing qualified resource result');
    const requiredFingerprint = value => { if (!Number.isSafeInteger(value?.bytes) || value.bytes <= 0 || !/^[a-f0-9]{64}$/.test(value.sha256)) throw new Error('Missing resource wire fingerprint'); };
    if (caseName === 'document-exact') { equal(proof.documentBytes, 32_000_000, 'document exact'); equal(proof.authorUndoPreservesPeer, true, 'author history'); requiredFingerprint(proof.accepted); }
    if (caseName === 'document-over') { equal(proof.documentBytes, 32_000_001, 'document one over'); equal(proof.historyAfterSecondRepair, 5, 'complete recovery history'); equal(proof.peerMetadataAndRichPreserved, true, 'peer preservation'); [proof.acceptedBefore, proof.pending, proof.repaired].forEach(requiredFingerprint); }
    if (caseName === 'retained-exact-over') { equal(proof.exactCapacityBytes, 64_000_000, 'retained exact'); equal(proof.rejectedCapacityBytes, 64_000_001, 'retained one over'); equal(proof.retainedBytes + proof.reserveBytes, 64_000_000, 'real capacity reserve'); requiredFingerprint(proof.accepted); requiredFingerprint(proof.callerOwnedRejected); equal(proof.cutoverEpoch, `cutover-v${version}`, 'explicit cutover'); }
    if (caseName === 'roots-exact') { equal(proof.rootBlocks, 10_000, 'root exact'); equal(proof.nestedPeerChildren, 1, 'root count excludes child'); equal(proof.authorUndoRootBlocks, 9_999, 'root author Undo'); requiredFingerprint(proof.accepted); }
    if (caseName === 'roots-over') { equal(proof.rejectedRootBlocks, 10_001, 'root one over'); equal(proof.repairedRootBlocks, 10_000, 'root repair'); equal(proof.historyAfterSecondRepair, 5, 'root retained history'); requiredFingerprint(proof.pending); requiredFingerprint(proof.repaired); }
    if (runtime === 'native') nativeProof = proof; else equal(proof, nativeProof, `${runtime}v${version}/${caseName} compact parity`);
  }
}
console.log('Verified105 current artifact-bound compact resource proofs at real32MB/64MB/10k-root thresholds; UI/host interaction remains separate.');
