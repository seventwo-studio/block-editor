import { SwiftModernCutover, SwiftModernSession } from "../src/swift-modern.js";
import type { ModernDocument, ModernObject, ModernTransport } from "../src/swift-modern.js";
import { ModernBrowserHost, ModernBrowserStore } from "../src/swift-modern-host.js";

export interface PreservationFixture { raw: string; document: ModernObject }
export type PreservationCase = "paired-reopen" | "migration-activation" | "migration-refusal" | "large-migration";
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(",")}}`;
  return JSON.stringify(value);
}
function check(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
function same(actual: unknown, expected: unknown, message: string): void { check(canonical(actual) === canonical(expected), message); }
const base64 = (bytes: Uint8Array) => btoa(Array.from(bytes, byte => String.fromCharCode(byte)).join(""));
const encoded = (value: string) => base64(new TextEncoder().encode(value));
async function refuses(operation: () => Promise<unknown>, message: string): Promise<void> {
  let rejected = false; try { await operation(); } catch { rejected = true; } check(rejected, message);
}
async function readArchive(database: string, revision: string): Promise<string> {
  const db = await new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open(database, 1);
    request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
  });
  try { return await new Promise((resolve, reject) => {
    const request = db.transaction("archives").objectStore("archives").get(revision);
    request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
  }); } finally { db.close(); }
}

/** Execute shared semantics and the real IndexedDB lifecycle against ST-140's
 * independent documents. These assertions do not certify rendered focus,
 * assistive navigation, physical input, or browser-process restart. */
export async function runModernPreservation(transport: ModernTransport, fixtures: Record<string, PreservationFixture>, scenario: PreservationCase) {
  const checks: string[] = [], sessions: SwiftModernSession[] = [];
  const database = `modern-preservation-${crypto.randomUUID()}`, store = new ModernBrowserStore(database);
  const fixture = (name: string) => { const value = fixtures[name]; check(value, `Missing independent fixture ${name}`); return value; };
  const close = (session: SwiftModernSession) => { session.close(); };
  function candidate(name: string, expectedName: string, epoch: string) {
    const source = fixture(name), expected = fixture(expectedName).document as unknown as ModernDocument;
    const archive = { version: 1 as const, documentID: expected.documentID, epoch,
      originals: [encoded(source.raw)], source: { document: { format: "blockArray" as const, bytes: encoded(JSON.stringify(source.document.blocks)) } } };
    const cutover = new SwiftModernCutover(transport), prepared = cutover.prepare(archive);
    try {
      check(prepared.status === "prepared", `${name}: compatible migration`);
      same(prepared.document, expected, `${name}: full independently authored migration projection`);
      const bytes = cutover.bytes(prepared.archiveID, 0, prepared.byteCount);
      cutover.verifyReadback(prepared.archiveID, 0, bytes.bytes);
      const session = SwiftModernSession.fromCutover(transport, prepared.archiveID, {
        actorID: "a", oldWritersStopped: true, archivePersisted: true, resetUndoAcknowledged: true,
      }).session;
      sessions.push(session);
      check(!session.getSnapshot().canUndo && !session.getSnapshot().canRedo && !session.getSnapshot().syncState.received.length, "Fresh epoch has no inherited history or receipt");
      return { archive: JSON.stringify(archive), session, pair: new ModernBrowserHost(session, "a", store, "detached").checkpoint() };
    } finally { cutover.forget(prepared.archiveID); }
  }
  try {
    if (scenario === "paired-reopen") {
      const expected = fixture("columns-7000").document as unknown as ModernDocument;
      const session = SwiftModernSession.create(transport, { actorID: "a", documentID: expected.documentID, epoch: "acceptance", document: expected }); sessions.push(session);
      const field = session.field(session.node({ blockID: "layout", path: ["columns", "first-column", "children", "A"] }));
      const range = session.captureTextRange(field, 1, 1), receipt = session.getSnapshot().syncState;
      session.setLocalSelection({ documentID: receipt.documentID, epoch: receipt.epoch, observed: range.observed,
        focus: { text: { _0: range.end } }, selection: { text: { _0: { start: range.start, end: range.end } } } });
      const host = new ModernBrowserHost(session, "a", store, "paired");
      host.retainInput({ range }, "not-yet-accepted 😀", "composition draft");
      await host.save(); const saved = await store.load("paired"); check(saved, "Paired checkpoint saved"); close(session);
      const reopened = ModernBrowserHost.restore(transport, saved, store, "paired"); sessions.push(reopened.host.session); reopened.resumeDeferred();
      same(reopened.host.session.getSnapshot().document, expected, "ACC-24: full document, scoped IDs, nesting and stored split");
      same(reopened.host.inputs, saved.inputs, "Unaccepted input remains a separate retained draft");
      const selection = reopened.host.session.exportHistorySelection().current;
      check(selection?.focus && "text" in selection.focus, "Explicit local caret restored");
      check(reopened.host.session.resolvePosition(selection.focus.text._0).offset === 1, "ACC-24: original caret resolves");
      const before = reopened.host.session.save(), beforeReceipt = reopened.host.session.getSnapshot().syncState;
      reopened.host.session.receive(reopened.host.session.changes());
      same(reopened.host.session.save(), before, "ACC-24: duplicate delivery does not alter accepted history");
      same(reopened.host.session.getSnapshot().syncState, beforeReceipt, "ACC-24: duplicate delivery does not advance receipt");
      check(!reopened.host.session.getSnapshot().canUndo && !reopened.host.session.getSnapshot().canRedo, "ACC-24: zero author history groups");
      checks.push("ACC-24 shared state, caret, independent pending input, idempotent duplicate, empty history");
    } else if (scenario === "migration-refusal") {
      for (const name of ["legacy-collision", "unsupported-inline"]) {
        const source = fixture(name), cutover = new SwiftModernCutover(transport);
        const archive = { version: 1 as const, documentID: `refused-${name}`, epoch: "new", originals: [encoded(source.raw)],
          source: { document: { format: "blockArray" as const, bytes: encoded(JSON.stringify(source.document.blocks)) } } };
        const result = cutover.prepare(archive);
        try {
          check(result.status === "unavailable", `ACC-26 ${name}: explicit refusal`);
          const count = cutover.bytes(result.archiveID, 0, 0).byteCount;
          const retained = JSON.parse(atob(cutover.bytes(result.archiveID, 0, count).bytes));
          same(retained.originals, archive.originals, `ACC-26 ${name}: exact source bytes retained`);
          check(await store.active("refused") === undefined, "Refusal never activates an empty or stripped replacement");
        } finally { cutover.forget(result.archiveID); }
        checks.push(`ACC-26 ${name}: unavailable, original bytes exportable, no activation`);
      }
    } else {
      const large = scenario === "large-migration", name = large ? "legacy-5001" : "legacy-mixed", expectedName = large ? "migrated-5001" : "migrated-mixed";
      const initial = candidate(name, expectedName, "epoch-one");
      const pointer = await store.activate("active", initial.archive, initial.pair, undefined, true, transport);
      const persisted = await store.loadActive("active"); check(persisted, "Candidate atomically activated");
      const reopened = ModernBrowserHost.restore(transport, persisted, store, pointer.liveKey); sessions.push(reopened.host.session); reopened.resumeDeferred();
      same(reopened.host.session.getSnapshot().document, fixture(expectedName).document, `${large ? "ACC-27" : "ACC-25"}: complete projected document after durable reopen`);
      same(JSON.parse(await readArchive(database, pointer.revision)).originals, [encoded(fixture(name).raw)], "Original fixture bytes durably retained");
      if (large) {
        check(reopened.host.session.getSnapshot().document.blocks.length === 5001, "ACC-27: no 5000-block host clipping");
        checks.push("ACC-27: all 5001 blocks and opaque fields, durable exact originals, full reopen, fresh history");
      } else {
        const next = candidate(name, expectedName, "epoch-two");
        // A real persisted stage followed by a failed readback must leave the
        // old active pointer intact. Retrying reads the same staged revision.
        class FailedReadbackStore extends ModernBrowserStore {
          override async load(key: string) { return key === next.pair.revision ? undefined : super.load(key); }
        }
        await refuses(() => new FailedReadbackStore(database).activate("active", next.archive, next.pair, pointer.revision, true, transport), "Failed readback must reject activation");
        same(await store.active("active"), pointer, "ACC-25: readback failure leaves original pointer unchanged");
        check(await store.load(next.pair.revision), "Failed candidate remains recoverable");
        const activated = await store.activate("active", next.archive, next.pair, pointer.revision, true, transport);
        const activePair = await store.loadActive("active"); check(activePair, "Second epoch activated");
        const active = ModernBrowserHost.restore(transport, activePair, store, activated.liveKey); sessions.push(active.host.session); active.resumeDeferred();
        const title = { node: { document: { documentID: activePair.documentID } }, name: "title" } as const;
        check(active.host.session.execute({ command: "replaceTitle", target: active.host.session.captureTextRange(title, 0, 0), arguments: { text: "New epoch work 😀" } }).status === "applied", "New epoch authored change");
        await active.host.save(); const edited = await store.load(activated.liveKey); check(edited, "New work saved before rollback");
        await store.rollback("active", activated.revision, true);
        same(await store.active("active"), pointer, "ACC-25: rollback returns to previous pointer");
        same(await store.load(activated.liveKey), edited, "ACC-25: rollback retains the newer epoch's work and Undo");
        same((await store.loadActive("active"))?.accepted, initial.pair.accepted, "Rollback never mixes histories or epochs");
        checks.push("ACC-25: full migration, exact originals, readback failure, idempotent stage retry, fresh epochs, rollback retaining later work");
      }
    }
    return { scenario, checks, evidence: "shared semantics and IndexedDB lifecycle only" };
  } finally { for (const session of sessions) session.close(); }
}
