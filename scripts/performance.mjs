// Shared by the native-process and browser-WASM measurement runners.
import { canonical } from './compatibility.mjs';

export function performanceOptions(config, options = {}) {
  if (config.version !== 1) throw new Error('Unsupported performance workload');
  const profile = options.profile ?? 'baseline';
  if (!['baseline', 'smoke'].includes(profile)) throw new Error('Unknown performance profile');
  const names = options.cases ?? (profile === 'smoke' ? ['ordinary-v1', 'ordinary-v2'] : config.cases.map(x => x.name));
  if (!names.length || new Set(names).size !== names.length) throw new Error('Empty/duplicated case selection');
  const cases = names.map(name => {
    const item = config.cases.find(x => x.name === name);
    if (!item) throw new Error(`Unknown performance case: ${name}`);
    return { ...item, editsPerAuthor: profile === 'smoke' ? 8 : item.editsPerAuthor };
  });
  const repetitions = options.repetitions ?? (profile === 'smoke' ? 1 : config.repetitions);
  const warmups = options.warmups ?? (profile === 'smoke' ? 0 : config.warmups);
  if (!Number.isInteger(repetitions) || repetitions < 1 || !Number.isInteger(warmups) || warmups < 0) throw new Error('Invalid repeat counts');
  return { profile, cases, repetitions, warmups };
}

export function summarize(samples) {
  const sorted = [...samples].sort((a, b) => a - b);
  if (!sorted.length || sorted.some(x => !Number.isFinite(x) || x < 0)) throw new Error('Invalid timing samples');
  const percentile = p => sorted[Math.max(0, Math.ceil(p * sorted.length) - 1)];
  return { count: sorted.length, totalMs: sorted.reduce((a, b) => a + b, 0), minMs: sorted[0], p50Ms: percentile(.5), p95Ms: percentile(.95), maxMs: sorted.at(-1), samplesMs: samples };
}

function equal(actual, expected, label) {
  if (JSON.stringify(canonical(actual)) !== JSON.stringify(canonical(expected))) throw new Error(`Performance correctness failure: ${label}`);
}
const bytes = value => new TextEncoder().encode(JSON.stringify(canonical(value))).byteLength;

/** Timings include the supplied adapter call, not rendering, network or asset fetch. */
export async function runPerformanceCase(config, workload, repetition, call, now = () => performance.now()) {
  const timings = {}, sessions = new Set();
  const handle = role => `perf-${workload.name}-${repetition}-${role}`;
  const a = handle('a'), b = handle('b'), peer = handle('peer'), reopened = handle('reopened');
  const address = { blockID: config.textBlockID, path: ['content'] };
  const request = async (phase, input) => {
    const start = now();
    const response = await call(input);
    const elapsed = now() - start;
    if (response.ok !== true) throw new Error(`${workload.name} ${phase}: ${response.error ?? 'missing response'}`);
    (timings[phase] ??= []).push(elapsed);
    if (['create', 'restore'].includes(input.command)) sessions.add(input.session);
    return response.value;
  };
  const create = (session, actorID) => request('create', { command: 'create', session, actorID, documentID: `performance-${workload.name}`, blocks: config.baseline, collaborationVersion: workload.version });
  const receive = (session, batch, phase = 'rejoin') => request(phase, { command: 'receive', session, batch });
  const assertContent = (snapshot, aCount, bCount) => {
    equal(snapshot.blocks.slice(1), config.baseline.slice(1), 'unrelated rich content and metadata');
    const block = snapshot.blocks[0];
    equal({ ...block, content: undefined }, { ...config.baseline[0], content: undefined }, 'text block identity and metadata');
    if (!Array.isArray(block.content) || block.content.some(x => x.type !== 'text')) throw new Error('Unexpected measured text shape');
    const text = block.content.map(x => x.text).join('');
    if (!text.endsWith(config.initialText)) throw new Error('Original Unicode text was lost');
    const prefix = text.slice(0, text.length - config.initialText.length);
    if (prefix.replace(/[ab]/g, '').length || [...prefix].filter(x => x === 'a').length !== aCount || [...prefix].filter(x => x === 'b').length !== bCount) throw new Error('Concurrent author text was lost');
  };
  const assertFormatting = (snapshot, boldCount, italicCount) => {
    const counts = { bold: 0, italic: 0 };
    for (const node of snapshot.blocks[0].content) {
      for (const [type, text] of [['bold', 'a'], ['italic', 'b']]) {
        if (!node.marks?.some(mark => mark.type === type)) continue;
        if (node.text !== text) throw new Error(`Performance correctness failure: ${type} escaped its author's character`);
        counts[type]++;
      }
    }
    equal(counts, { bold: boldCount, italic: italicCount }, 'author formatting and undo');
  };
  try {
    equal((await create(a, 'a')).blocks, config.baseline, 'initial document');
    await create(b, 'b');
    for (let index = 0; index < workload.editsPerAuthor; index++) {
      for (const [session, text] of [[a, 'a'], [b, 'b']]) {
        await request('offlineEdit', { command: 'replaceText', session, address, start: 0, end: 0, text, marks: [] });
      }
    }
    for (const [session, type] of [[a, 'bold'], [b, 'italic']]) {
      await request('format', { command: 'format', session, address, start: 0, end: 1, markType: type, mark: { type } });
    }
    const batchA = await request('exchangeExport', { command: 'changes', session: a });
    const batchB = await request('exchangeExport', { command: 'changes', session: b });
    equal(batchA.changes.length, workload.editsPerAuthor + 1, 'A retained edit history');
    equal(batchB.changes.length, workload.editsPerAuthor + 1, 'B retained edit history');
    const reverse = batch => ({ ...batch, changes: [...batch.changes].reverse() });
    const duplicate = batch => ({ ...batch, changes: [...batch.changes, ...batch.changes] });
    const finalA = await receive(a, duplicate(reverse(batchB)));
    const finalB = await receive(b, reverse(batchA));
    equal(finalA.blocks, finalB.blocks, 'offline rejoin convergence');
    assertContent(finalA, workload.editsPerAuthor, workload.editsPerAuthor);
    assertFormatting(finalA, 1, 1);
    equal((await receive(a, batchB, 'duplicateReceive')).blocks, finalA.blocks, 'already acknowledged duplicate');
    await create(peer, 'peer');
    const combined = { ...batchA, changes: [...batchA.changes, ...batchB.changes].reverse() };
    equal((await receive(peer, combined, 'fullHistoryReceive')).blocks, finalA.blocks, 'fresh replica replay');
    const saved = await request('save', { command: 'save', session: a });
    const receipts = await request('receipts', { command: 'syncState', session: a });
    equal(saved.changes.length, workload.editsPerAuthor * 2 + 2, 'saved history size');
    equal(receipts.received.length, saved.changes.length, 'exact receipts');
    equal((await request('restore', { command: 'restore', session: reopened, actorID: 'a', snapshot: saved })).blocks, finalA.blocks, 'save/reopen');
    equal(await request('receipts', { command: 'syncState', session: reopened }), receipts, 'reopened receipts');
    const afterFormatUndo = await request('undo', { command: 'undo', session: reopened });
    assertFormatting(afterFormatUndo, 0, 1);
    const afterUndo = await request('undo', { command: 'undo', session: reopened });
    assertContent(afterUndo, workload.editsPerAuthor - 1, workload.editsPerAuthor);
    assertFormatting(afterUndo, 0, 1);
    await request('redo', { command: 'redo', session: reopened });
    equal((await request('redo', { command: 'redo', session: reopened })).blocks, finalA.blocks, 'redo retains remote content');
    return {
      case: workload.name, repetition, version: workload.version, editsPerAuthor: workload.editsPerAuthor,
      metrics: Object.fromEntries(Object.entries(timings).map(([phase, values]) => [phase, summarize(values)])),
      sizes: { baselineBytes: bytes(config.baseline), snapshotBytes: bytes(saved), exchangeBytes: bytes(combined), changes: saved.changes.length, receipts: receipts.received.length },
      finalBlocks: canonical(finalA.blocks),
    };
  } finally {
    for (const session of sessions) {
      const response = await call({ command: 'close', session });
      if (response.ok !== true) throw new Error(`Failed to close benchmark session ${session}`);
    }
  }
}

export async function runPerformance(config, options, call, onSample = () => {}) {
  for (const workload of options.cases) {
    for (let repeat = -options.warmups; repeat < options.repetitions; repeat++) {
      const sample = await runPerformanceCase(config, workload, repeat, call);
      if (repeat >= 0) await onSample(sample);
    }
  }
}
