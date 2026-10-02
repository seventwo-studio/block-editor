// Production resource limits exercised through the unchanged shared JSON bridge.
// Reports are compact, explicit resource proofs; they are not raw transcripts.
import { canonical } from './compatibility.mjs';
export const resourceBytes = value => new TextEncoder().encode(JSON.stringify(canonical(value)));
const same = (actual, expected, label) => {
  if (JSON.stringify(canonical(actual)) !== JSON.stringify(canonical(expected))) throw new Error(`Resource contract: ${label}`);
};
const require_ = (condition, label) => { if (!condition) throw new Error(`Resource contract: ${label}`); };
const padding = count => 'é'.repeat(Math.floor(count / 2)) + (count % 2 ? 'x' : '');

export function validateResourceSpec(spec) {
  same(spec.version, 1, 'spec version');
  same(spec.protocols, [4, 5, 6], 'finite protocols');
  same(spec.cases, ['document-exact', 'document-over', 'retained-exact-over', 'roots-exact', 'roots-over'], 'complete cases');
  same(spec.limits, { documentBytes: 32_000_000, retainedBytes: 64_000_000, rootBlocks: 10_000, retainedReserveBytes: 1_024 }, 'actual production limits');
}
export async function runWritingResourceCase(spec, version, caseName, call, digest) {
  validateResourceSpec(spec);
  require_(spec.protocols.includes(version) && spec.cases.includes(caseName), 'known case/version');
  const sessions = new Set(), base = structuredClone(spec.baseline), owner = { baseline: { blockID: 'owner', path: [] } };
  const documentID = `packaged-resource-${version}-${caseName}`, epoch = `resource-v${version}`;
  const fingerprint = async value => { const bytes = resourceBytes(value); return { bytes: bytes.length, sha256: await digest(bytes) }; };
  const request = async (command, session, fields = {}, error) => {
    const result = await call({ command, session, ...fields });
    same(result.ok, !error, `${command} success`);
    if (error) { same(result.error, error, `${command} error`); return result.recovery; }
    if (command === 'create' || command === 'restore') sessions.add(session);
    if (command === 'close') sessions.delete(session);
    return result.value;
  };
  const create = (session, actorID, blocks = base, extra = {}) => request('create', session, { documentID, actorID, epoch, collaborationVersion: version, blocks, ...extra });
  const field = (session, name, value) => request('setNodeField', session, { identity: owner, path: ['consumer', name], value });
  const rich = snapshot => same(snapshot.blocks[0].content, base[0].content, 'rich Unicode/reference/marks preserved');
  const save = session => request('save', session);
  const receipt = session => request('syncState', session);
  const equalAccepted = async (session, saved, received) => {
    same(await save(session), saved, 'accepted save unchanged'); same(await receipt(session), received, 'accepted receipt unchanged');
  };
  const repair = (session, actor = 'a') => request('repairWritingUndo', session, { target: { counter: 1, actor } }, actor === 'a' ? undefined : 'invalidChange');
  let primaryFailure;
  try {
    if (caseName.startsWith('document-')) {
      const excess = caseName === 'document-over' ? 1 : 0;
      const payload = spec.limits.documentBytes - resourceBytes(base).length + excess;
      const left = padding(Math.floor(payload / 2)), right = padding(payload - Math.floor(payload / 2));
      const expected = structuredClone(base); expected[0].consumer.left = left; expected[0].consumer.right = right;
      same(resourceBytes(expected).length, 32_000_000 + excess, 'literal canonical document boundary');
      await create('a', 'a'); await create('b', 'b');
      await field('a', 'left', left); await field('b', 'right', right);
      const aSave = await save('a'), bSave = await save('b'), aReceipt = await receipt('a'), bReceipt = await receipt('b');
      const aBatch = await request('changes', 'a'), bBatch = await request('changes', 'b');
      if (!excess) {
        const accepted = await request('receive', 'a', { batch: bBatch });
        same(accepted.blocks, expected, 'exact document admitted'); rich(accepted);
        same((await request('receive', 'b', { batch: await request('changes', 'a') })).blocks, expected, 'exact union converges');
        same((await request('receive', 'a', { batch: bBatch })).blocks, expected, 'duplicate exact union');
        const acceptedSave = await save('a'); await request('restore', 'r', { snapshot: acceptedSave, actorID: 'a' });
        const undone = await request('undo', 'r'); same(undone.blocks[0].consumer.left, '', 'own Undo'); same(undone.blocks[0].consumer.right, right, 'peer survives Undo'); rich(undone);
        same((await request('redo', 'r')).blocks, expected, 'Redo/reopen');
        return { case: caseName, version, documentBytes: resourceBytes(expected).length, accepted: await fingerprint(acceptedSave), receipt: await receipt('a'), authorUndoPreservesPeer: true };
      }
      const proposal = await request('receive', 'a', { batch: bBatch }, 'writingRecoveryRequired');
      same(await request('receive', 'b', { batch: aBatch }, 'writingRecoveryRequired'), proposal, 'both retained proposals');
      same(await request('receive', 'a', { batch: bBatch }, 'writingRecoveryRequired'), proposal, 'duplicate recovery');
      same(proposal.reason, 'schemaConstraint', 'document size recovery reason'); same(proposal.batch.changes.length, 2, 'both changes retained');
      await equalAccepted('a', aSave, aReceipt); await equalAccepted('b', bSave, bReceipt);
      await request('restore', 'r', { snapshot: aSave, actorID: 'a' });
      same(await request('restoreRecovery', 'r', { recovery: proposal }, 'writingRecoveryRequired'), proposal, 'separate restart recovery');
      await repair('r', 'b'); await equalAccepted('r', aSave, aReceipt); same(await request('mergeRecovery', 'r'), proposal, 'failed repair pending unchanged');
      const repaired = await repair('r'); same(repaired.blocks[0].consumer.left, '', 'explicit own repair'); same(repaired.blocks[0].consumer.right, right, 'peer metadata repair'); rich(repaired);
      same(await request('mergeRecovery', 'r'), null, 'recovery cleared after valid admission');
      const repairedBatch = await request('changes', 'r'); same(repairedBatch.changes.length, 3, 'repair preserves original history');
      const reversed = { ...repairedBatch, changes: [...repairedBatch.changes].reverse() };
      same((await request('receive', 'b', { batch: reversed })).blocks, repaired.blocks, 'reversed repaired union'); await request('receive', 'b', { batch: repairedBatch });
      const repairedSave = await save('r'), repairedReceipt = await receipt('r');
      const redo = await request('redo', 'r', {}, 'writingRecoveryRequired'); await equalAccepted('r', repairedSave, repairedReceipt);
      await request('restore', 'rr', { snapshot: repairedSave, actorID: 'a' }); await request('restoreRecovery', 'rr', { recovery: redo }, 'writingRecoveryRequired');
      same((await repair('rr')).blocks, repaired.blocks, 'restarted rejected Redo repair'); same((await request('changes', 'rr')).changes.length, 5, 'all failed and repair changes retained');
      return { case: caseName, version, documentBytes: resourceBytes(expected).length, acceptedBefore: await fingerprint(aSave), pending: await fingerprint(proposal), repaired: await fingerprint(repairedSave), historyAfterSecondRepair: 5, peerMetadataAndRichPreserved: true };
    }
    if (caseName === 'retained-exact-over') {
      await create('author', 'a'); for (const value of ['one', 'two', 'three', 'four']) await field('author', 'history', value);
      const template = await request('changes', 'author');
      same(template.changes.map(x => x.id), [1, 2, 3, 4].map(counter => ({ counter, actor: 'a' })), 'real authored template IDs');
      const make = sizes => ({ ...template, changes: template.changes.map((change, i) => {
        const operations = change.body.edit?._0; require_(operations?.length === 1 && operations[0].structure?._0?.setNodeField, 'authentic scalar operation');
        const mutation = operations[0].structure._0.setNodeField;
        same(mutation.path, ['consumer', 'history'], 'retained operation path'); same(mutation.identity, owner, 'retained operation owner');
        return { ...change, body: { edit: { _0: [{ structure: { _0: { setNodeField: { ...mutation, value: String(i).repeat(sizes[i]) } } } }] } } };
      }) });
      const reserve = 1_024 + resourceBytes(template.changes.map(x => x.id)).length;
      const payload = 64_000_000 - reserve - resourceBytes(make([0, 0, 0, 0])).length;
      const quarter = Math.floor(payload / 4), sizes = [quarter, quarter, quarter, payload - 3 * quarter], exact = make(sizes);
      const exactBytes = resourceBytes(exact).length; same(exactBytes + reserve, 64_000_000, 'exact retained capacity reserve');
      await create('receiver', 'a'); const accepted = await request('receive', 'receiver', { batch: exact }); rich(accepted);
      same(accepted.blocks[0].consumer.history, '3'.repeat(sizes[3]), 'last scalar value');
      const acceptedSave = await save('receiver'), acceptedReceipt = await receipt('receiver'); require_(resourceBytes(acceptedSave).length <= 64_000_000, 'exact save fits');
      const restarted = await request('restore', 'restarted', { snapshot: acceptedSave, actorID: 'a' }); same(restarted.blocks, accepted.blocks, 'exact save reopens'); same(await receipt('restarted'), acceptedReceipt, 'exact receipt reopens');
      await create('stopped', 'b'); await request('receive', 'stopped', { batch: { ...exact, changes: exact.changes.slice(0, 3) } });
      const stoppedSave = await save('stopped'), stoppedReceipt = await receipt('stopped'); const over = make([...sizes.slice(0, 3), sizes[3] + 1]);
      same(resourceBytes(over).length + reserve, 64_000_001, 'over capacity one byte');
      await request('receive', 'stopped', { batch: over }, 'recoveryCapacityExceeded'); await equalAccepted('stopped', stoppedSave, stoppedReceipt); same(await request('mergeRecovery', 'stopped'), null, 'over-capacity cannot append pending');
      await request('restore', 'resumed', { snapshot: stoppedSave, actorID: 'b' });
      const callerArchive = JSON.parse(JSON.stringify(over)); await request('receive', 'resumed', { batch: callerArchive }, 'recoveryCapacityExceeded'); await equalAccepted('resumed', stoppedSave, stoppedReceipt);
      const cutoverEpoch = `cutover-v${version}`; await create('cutover', 'b', (await request('document', 'resumed')).blocks, { epoch: cutoverEpoch });
      await field('cutover', 'left', 'after-cutover'); same((await receipt('cutover')).received.length, 1, 'explicit new epoch author history');
      await request('receive', 'cutover', { batch: callerArchive }, 'differentDocument');
      const cutoverSave = await save('cutover'); const stale = { ...callerArchive, baseline: cutoverSave.baseline, epoch, changes: [] };
      await request('receive', 'cutover', { batch: stale }, 'incompatibleEpoch');
      same((await request('restore', 'cutover-reopened', { snapshot: cutoverSave, actorID: 'b' })).blocks, (await request('document', 'cutover')).blocks, 'cutover save');
      return { case: caseName, version, retainedBytes: exactBytes, reserveBytes: reserve, exactCapacityBytes: 64_000_000, rejectedCapacityBytes: 64_000_001, accepted: await fingerprint(acceptedSave), callerOwnedRejected: await fingerprint(callerArchive), stoppedReceipt, cutoverEpoch };
    }
    const roots = caseName === 'roots-exact' ? 9_998 : 9_999;
    const baseline = [base[0], ...Array.from({ length: roots - 1 }, (_, i) => ({ id: `root-${i + 1}`, type: 'paragraph', content: [{ type: 'text', text: '', marks: [] }] }))];
    await create('a', 'a', baseline); await create('b', 'b', baseline);
    const last = { baseline: { blockID: `root-${roots - 1}`, path: [] } };
    const ownNode = { id: 'A', type: 'paragraph', content: [{ type: 'text', text: 'author', marks: [] }] };
    const peerNode = { id: 'B', type: 'toggle', summary: [{ type: 'text', text: 'peer 東京😀', marks: [] }], children: [{ id: 'peer-child', type: 'paragraph', content: base[0].content, consumer: { id: 'peer-opaque' } }], consumer: { id: 'B-opaque' } };
    await request('insertCollectionNodes', 'a', { values: [ownNode], collection: { field: 'blocks' }, after: last });
    await request('insertCollectionNodes', 'b', { values: [peerNode], collection: { field: 'blocks' }, after: last });
    const peerIdentity = await request('node', 'b', { address: { blockID: 'B', path: [] } }), childIdentity = await request('node', 'b', { address: { blockID: 'B', path: ['children', 'peer-child'] } });
    const aSave = await save('a'), bSave = await save('b'), aReceipt = await receipt('a'), bReceipt = await receipt('b');
    const aBatch = await request('changes', 'a'), bBatch = await request('changes', 'b');
    const check = snapshot => { same(snapshot.blocks.length, 10_000, 'root count is not descendants'); rich(snapshot); same(snapshot.blocks.find(x => x.id === 'B'), peerNode, 'peer subtree/metadata'); };
    if (roots === 9_998) {
      const combined = await request('receive', 'a', { batch: bBatch }); check(combined); same((await request('receive', 'b', { batch: await request('changes', 'a') })).blocks, combined.blocks, 'exact root union'); await request('receive', 'a', { batch: bBatch });
      const acceptedSave = await save('a'); await request('restore', 'r', { snapshot: acceptedSave, actorID: 'a' });
      const undone = await request('undo', 'r'); same(undone.blocks.length, 9_999, 'root author Undo'); same(undone.blocks.find(x => x.id === 'B'), peerNode, 'peer subtree after Undo');
      same((await request('redo', 'r')).blocks, combined.blocks, 'root Redo');
      return { case: caseName, version, rootBlocks: 10_000, nestedPeerChildren: 1, accepted: await fingerprint(acceptedSave), peerIdentity, childIdentity, authorUndoRootBlocks: 9_999 };
    }
    const proposal = await request('receive', 'a', { batch: bBatch }, 'writingRecoveryRequired'); same(await request('receive', 'b', { batch: aBatch }, 'writingRecoveryRequired'), proposal, 'root proposals'); same(await request('receive', 'a', { batch: bBatch }, 'writingRecoveryRequired'), proposal, 'root duplicate pending');
    same(proposal.reason, 'schemaConstraint', 'root recovery reason'); await equalAccepted('a', aSave, aReceipt); await equalAccepted('b', bSave, bReceipt);
    await request('restore', 'r', { snapshot: aSave, actorID: 'a' }); await request('restoreRecovery', 'r', { recovery: proposal }, 'writingRecoveryRequired');
    await repair('r', 'b'); await equalAccepted('r', aSave, aReceipt); same(await request('mergeRecovery', 'r'), proposal, 'failed root repair retained');
    const repaired = await repair('r'); check(repaired); require_(!repaired.blocks.some(x => x.id === 'A'), 'own inserted root retired');
    same(await request('node', 'r', { address: { blockID: 'B', path: [] } }), peerIdentity, 'peer origin'); same(await request('node', 'r', { address: { blockID: 'B', path: ['children', 'peer-child'] } }), childIdentity, 'peer child origin');
    const batch = await request('changes', 'r'); same(batch.changes.length, 3, 'retained repaired roots'); await request('receive', 'b', { batch: { ...batch, changes: [...batch.changes].reverse() } }); await request('receive', 'b', { batch });
    const repairedSave = await save('r'), repairedReceipt = await receipt('r'); const redo = await request('redo', 'r', {}, 'writingRecoveryRequired'); await equalAccepted('r', repairedSave, repairedReceipt);
    await request('restore', 'rr', { snapshot: repairedSave, actorID: 'a' }); await request('restoreRecovery', 'rr', { recovery: redo }, 'writingRecoveryRequired'); same((await repair('rr')).blocks, repaired.blocks, 'root restarted Redo repair'); same((await request('changes', 'rr')).changes.length, 5, 'all root repair history');
    return { case: caseName, version, rejectedRootBlocks: 10_001, repairedRootBlocks: 10_000, pending: await fingerprint(proposal), repaired: await fingerprint(repairedSave), peerIdentity, childIdentity, historyAfterSecondRepair: 5 };
  } catch (error) { primaryFailure = error; throw error; }
  finally {
    const cleanupFailures = [];
    for (const session of [...sessions]) {
      try { await request('close', session); } catch (error) { cleanupFailures.push(error); }
    }
    if (cleanupFailures.length) {
      if (primaryFailure instanceof Error) primaryFailure.cleanupFailures = cleanupFailures.map(String);
      else if (primaryFailure === undefined) throw new AggregateError(cleanupFailures, 'Resource session cleanup failed');
    }
  }
}
