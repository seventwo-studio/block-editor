import { test, expect } from "bun:test";
import { SwiftModernSession, type ModernSnapshot, type ModernTransport } from "../src/swift-modern";

function fixture(): ModernSnapshot {
  return { version: 7, canUndo: false, canRedo: false, recovery: null,
    syncState: { version: 7, documentID: "shared", epoch: "epoch", received: [] },
    document: { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "shared", title: "Title",
      appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" },
      blocks: [{ id: "a", type: "paragraph", content: [{ type: "text", text: "A😀" }] }],
      opaque: JSON.parse('{"zero":0,"spelling":"é","__proto__":{"retain":true}}') } };
}
function setup() {
  let current = fixture();
  (current.document.opaque as { zero: number }).zero = -0;
  const transport: ModernTransport = { call<T>(request: Record<string, unknown>): T {
    if (request.command === "modernCommand") return { ...structuredClone(current), status: "noop", transaction: null, focus: null, selection: null } as T;
    return structuredClone(current) as T;
  } };
  const session = SwiftModernSession.create(transport, { actorID: "a", documentID: "shared", epoch: "epoch", document: current.document });
  return { session, set: (value: ModernSnapshot) => { current = value; }, current: () => current };
}

test("equal document/receipt reuse immutable values while state and notifications publish", () => {
  const { session, set, current } = setup(), before = session.getSnapshot(); let notifications = 0;
  session.subscribe(() => { notifications++; });
  set({ ...current(), canUndo: true }); session.endTypingGroup();
  const after = session.getSnapshot();
  expect(after).not.toBe(before); expect(after.canUndo).toBe(true);
  expect(after.document).toBe(before.document); expect(after.syncState).toBe(before.syncState);
  expect(Object.is((after.document.opaque as { zero: number }).zero, -0)).toBe(true);
  const result = session.execute({ command: "undo", target: null, arguments: {} });
  expect(result.document).toBe(session.getSnapshot().document); expect(notifications).toBe(2);
  expect(Object.isFrozen(after.document.blocks)).toBe(true);
  expect(Object.getPrototypeOf(after.document.opaque)).toBe(Object.prototype);
  expect(Object.hasOwn(after.document.opaque as object, "__proto__")).toBe(true);
});

test("signed zero, exact Unicode and same-cohort document changes are never hidden", () => {
  const { session, set, current } = setup(); const before = session.getSnapshot();
  const doc = structuredClone(current().document);
  (doc.opaque as { zero: number; spelling: string }).zero = 0;
  (doc.opaque as { spelling: string }).spelling = "é";
  set({ ...current(), document: doc }); session.endTypingGroup();
  const after = session.getSnapshot();
  expect(after.document).not.toBe(before.document); expect(after.document.blocks).toBe(before.document.blocks);
  expect(Object.is((after.document.opaque as { zero: number }).zero, 0)).toBe(true);
  expect((after.document.opaque as { spelling: string }).spelling).toBe("é");
  const oldDocument = after.document;
  set({ ...current(), syncState: { ...current().syncState, received: [{ counter: 1, actor: "peer" }] } }); session.endTypingGroup();
  expect(session.getSnapshot().document).toBe(oldDocument);
  expect(session.getSnapshot().syncState).not.toBe(after.syncState);
});

test("optional binding read falls back once for old engines and propagates genuine failures", () => {
  let calls = 0;
  const session = SwiftModernSession.create({ call<T>(request: Record<string, unknown>): T {
    if (request.command === "modernNodeBindings") { calls++; throw new Error("invalidChange"); }
    return fixture() as T;
  } }, { actorID: "a", documentID: "shared", epoch: "epoch", document: fixture().document });
  expect(session.nodeBindings()).toBeUndefined(); expect(session.nodeBindings()).toBeUndefined(); expect(calls).toBe(1);
  const failed = SwiftModernSession.create({ call<T>(request: Record<string, unknown>): T {
    if (request.command === "modernNodeBindings") throw new Error("scopeClosed"); return fixture() as T;
  } }, { actorID: "a", documentID: "shared", epoch: "epoch", document: fixture().document });
  expect(() => failed.nodeBindings()).toThrow("scopeClosed");
});

test("shared binding tokens preserve exact array ownership and reject an unknown omitted view", () => {
  let unknown = false, fail = false, reads = 0;
  const bindings = [{ address: { blockID: "A", path: [] }, node: { baseline: { blockID: "A", path: [] } }, kind: "block", fields: {} }];
  const session = SwiftModernSession.create({ call<T>(request: Record<string, unknown>): T {
    if (request.command === "modernCapabilities") return { renderingBindingVersion: 1 } as T;
    if (request.command === "modernRenderingBindings") {
      reads++; if (fail) throw new Error("invalidChange");
      return { token: unknown ? "foreign" : "owned", bindings: reads === 1 ? bindings : null } as T;
    }
    return fixture() as T;
  } }, { actorID: "a", documentID: "shared", epoch: "epoch", document: fixture().document });
  const first = session.nodeBindings(); expect(session.nodeBindings()).toBe(first); expect(Object.isFrozen(first)).toBe(true);
  unknown = true; expect(() => session.nodeBindings()).toThrow("omitted unknown bindings");
  unknown = false; fail = true; expect(() => session.nodeBindings()).toThrow("invalidChange");
});

test("compact local selection retains accepted snapshot and notifies persistence after checked acknowledgement", () => {
  let fail = false, foreign = false, capabilityReads = 0;
  const requests: Record<string, unknown>[] = [];
  const session = SwiftModernSession.create({ call<T>(request: Record<string, unknown>): T {
    if (request.command === "modernCapabilities") { capabilityReads++; return { localSelectionAckVersion: 1 } as T; }
    if (request.command === "modernSetLocalSelection") {
      requests.push(request); if (fail) throw new Error("invalidSelection");
      return (request.includeSnapshot === false ? { version: 1, documentID: "shared", epoch: foreign ? "foreign" : "epoch" } : fixture()) as T;
    }
    return fixture() as T;
  } }, { actorID: "a", documentID: "shared", epoch: "epoch", document: fixture().document });
  const initial = session.getSnapshot(); let notifications = 0;
  session.subscribe(() => { notifications++; expect(session.getSnapshot()).toBe(initial); });
  session.setLocalSelection(null); session.setLocalSelection(null);
  expect(requests.every(request => request.includeSnapshot === false)).toBe(true);
  expect(capabilityReads).toBe(1); expect(notifications).toBe(2);
  foreign = true; expect(() => session.setLocalSelection(null)).toThrow("incompatible scope");
  fail = true; expect(() => session.setLocalSelection(null)).toThrow("invalidSelection");
  expect(notifications).toBe(2); expect(session.getSnapshot()).toBe(initial);
});

test("old engines retain full local selection snapshots and notifications", () => {
  const requests: Record<string, unknown>[] = [];
  const session = SwiftModernSession.create({ call<T>(request: Record<string, unknown>): T {
    requests.push(request);
    return (request.command === "modernCapabilities" ? {} : fixture()) as T;
  } }, { actorID: "a", documentID: "shared", epoch: "epoch", document: fixture().document });
  let notifications = 0; session.subscribe(() => { notifications++; });
  session.setLocalSelection(null); session.setLocalSelection(null);
  expect(notifications).toBe(2);
  expect(requests.filter(request => request.command === "modernSetLocalSelection").every(request => !("includeSnapshot" in request))).toBe(true);
});

test("negotiated snapshots preserve full documents, opaque ownership and same-value peer receipts", () => {
  const initial = fixture(); const opaque = initial.document.opaque as { zero: number; spelling: string; __proto__: { retain: boolean } };
  opaque.zero = -0; Object.freeze(opaque); // A foreign shallow freeze is not proof of owned descendants.
  let phase = 0; const requests: Record<string, unknown>[] = [];
  const session = SwiftModernSession.create({ call<T>(request: Record<string, unknown>): T {
    requests.push(request);
    if (request.command === "modernCapabilities") return { documentSnapshotVersion: 1 } as T;
    if (request.command !== "modernCommand") return initial as T;
    phase++;
    const base = { version: 7, canUndo: true, canRedo: false, recovery: null, status: "applied", transaction: null, focus: null, selection: null,
      syncState: { version: 7, documentID: "shared", epoch: "epoch", received: [{ actor: "peer", counter: phase }] } };
    if (phase === 1) return { ...base, document: structuredClone(initial.document), documentSnapshot: { version: 1, token: "first" } } as T;
    if (phase === 2) return { ...base, documentSnapshot: { version: 1, token: "second", baseToken: "first", changes: [
      { path: ["blocks", 0, "content", 0, "text"], value: "東京😀" }, { path: ["opaque", "spelling"], value: "é" },
      { path: ["opaque", "zero"], value: 0 }, { path: ["opaque", "__proto__", "retain"], value: false }] } } as T;
    return { ...base, documentSnapshot: { version: 1, token: "second", baseToken: "second", changes: [] } } as T;
  } }, { actorID: "a", documentID: "shared", epoch: "epoch", document: initial.document });
  expect(Object.isFrozen(opaque.__proto__)).toBe(true);
  const before = session.getSnapshot(); session.execute({ command: "undo", arguments: {} });
  expect(session.getSnapshot().document).toBe(before.document);
  session.execute({ command: "undo", arguments: {} });
  const expected = structuredClone(initial.document);
  (expected.blocks[0].content as { text: string }[])[0].text = "東京😀";
  (expected.opaque as typeof opaque).spelling = "é"; (expected.opaque as typeof opaque).zero = 0;
  (expected.opaque as typeof opaque).__proto__.retain = false;
  const changed = session.getSnapshot(); expect(changed.document).toEqual(expected);
  expect(Object.getPrototypeOf(changed.document.opaque)).toBe(Object.prototype);
  expect((before.document.opaque as typeof opaque).spelling).toBe("é"); expect(Object.is((before.document.opaque as typeof opaque).zero, -0)).toBe(true);
  expect(Object.isFrozen((changed.document.opaque as typeof opaque).__proto__)).toBe(true);
  session.execute({ command: "undo", arguments: {} });
  expect(session.getSnapshot().document).toBe(changed.document); expect(session.getSnapshot().syncState.received[0].counter).toBe(3);
  expect(requests.filter(request => request.command === "modernCommand").map(request => request.knownDocumentToken)).toEqual([undefined, "first", "second"]);
});

test("advertised malformed snapshots never publish or replace the accepted document", () => {
  for (const failure of ["base", "overlap", "array", "scope", "ambiguous"]) {
    let count = 0;
    const session = SwiftModernSession.create({ call<T>(request: Record<string, unknown>): T {
      if (request.command === "modernCapabilities") return { documentSnapshotVersion: 1 } as T;
      if (request.command !== "modernCommand") return fixture() as T;
      count++;
      if (count === 1) return { ...fixture(), documentSnapshot: { version: 1, token: "known" } } as T;
      const { document, ...snapshot } = fixture();
      const changes = failure === "overlap" ? [{ path: ["title"], value: "X" }, { path: ["title"], value: "Y" }] :
        failure === "array" ? [{ path: ["blocks", 2], value: {} }] : [];
      return { ...snapshot, ...(failure === "ambiguous" ? { document } : {}),
        syncState: { ...snapshot.syncState, epoch: failure === "scope" ? "foreign" : "epoch" },
        documentSnapshot: { version: 1, token: "next", baseToken: failure === "base" ? "foreign" : "known", changes } } as T;
    } }, { actorID: "a", documentID: "shared", epoch: "epoch", document: fixture().document });
    session.execute({ command: "undo", arguments: {} }); const before = session.getSnapshot(); let notifications = 0;
    session.subscribe(() => { notifications++; });
    expect(() => session.execute({ command: "undo", arguments: {} })).toThrow();
    expect(session.getSnapshot()).toBe(before); expect(notifications).toBe(0);
  }
});
