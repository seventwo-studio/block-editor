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
