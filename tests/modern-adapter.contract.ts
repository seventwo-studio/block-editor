import { SwiftModernSession, SwiftModernCutover, SwiftModernRecoveryError } from "../src/swift-modern.js";
import type { ModernTransport, ModernDocument, ModernObject, ModernNodeID, ModernField, ModernResult, ModernScope, ModernJSON } from "../src/swift-modern.js";
import type { SwiftTextPosition } from "../src/swift.js";

function check(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(",")}}`;
  return JSON.stringify(value);
}
function same(a: unknown, b: unknown, message: string): void { check(canonical(a) === canonical(b), message); }
function rejected(operation: () => unknown, message: string): unknown { try { operation(); } catch (error) { return error; } throw new Error(message); }
const node = (blockID: string, path: readonly string[] = []): ModernNodeID => ({ baseline: { blockID, path } });
const field = (id: string): ModernField => ({ node: node(id), name: "content" });
const paragraph = (id: string, text = ""): ModernObject => ({ id, type: "paragraph", content: text ? [{ type: "text", text }] : [] });
const document = (documentID: string, blocks: readonly ModernObject[] = [paragraph("p", "abcd")]): ModernDocument => ({
  format: "seventwo.block-editor.document", formatVersion: 1, documentID, title: "Title",
  appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable", consumer: { text: "opaque preset metadata" } }, blocks,
  consumer: { children: [{ id: "opaque", text: "untouched" }] },
});

/** The same consumer operations run through the native C ABI and the browser WASM
 * runtime. Assertions inspect accepted content/receipts and independently authored fixtures. */
export function runModernAdapterContract(sourceTransport: ModernTransport, fixtures: readonly { name: string; document: ModernDocument }[] = []): { checks: readonly string[]; fixtures: number; appliedCommands: readonly string[] } {
  const appliedCommands = new Set<string>();
  const transport: ModernTransport = { call<T>(request: Record<string, unknown>): T {
    const value = sourceTransport.call<T>(request);
    if (request.command === "modernCommand" && (value as ModernResult).status === "applied") appliedCommands.add((request.request as { command: string }).command);
    return value;
  } };
  const checks: string[] = [], sessions: SwiftModernSession[] = [];
  const create = (actorID: string, doc = document(`adapter-${crypto.randomUUID()}`), epoch = "epoch") => {
    const s = SwiftModernSession.create(transport, { actorID, documentID: doc.documentID, epoch, document: doc }); sessions.push(s); return s;
  };
  const restore = (s: SwiftModernSession, actorID = "a") => { const r = SwiftModernSession.restore(transport, s.save(), actorID); sessions.push(r); return r; };
  const applied = (r: ModernResult) => { check(r.status === "applied" && r.transaction !== null, `Expected applied, got ${r.status}/${r.reason}`); return r; };
  try {
    const shared = document("adapter-shared"), a = create("a", shared), b = create("b", shared);
    check(a.capabilities().commands.length === 26, "All core commands available");
    const initial = a.getSnapshot(); check(Object.isFrozen(initial) && Object.isFrozen(initial.document.blocks) && Object.isFrozen(initial.document.consumer), "Published state is deeply immutable");
    rejected(() => { (initial.document as { title: string }).title = "corrupt"; }, "Snapshot cannot be overwritten");
    let observed = 0; a.subscribe(() => { observed++; check(a.getSnapshot().syncState.received.length > 0, "Publish before notification"); });
    const captured = a.captureTextRange(field("p"), 3, 1);
    applied(b.execute({ command: "replaceText", target: b.captureTextRange(field("p"), 2, 2), arguments: { text: "X" } }));
    a.receive(b.changes());
    const edited = applied(a.execute({ command: "replaceText", target: captured, arguments: { text: "😀" } }));
    same(edited.document.blocks[0]?.content, [{ type: "text", text: "a😀Xd" }], "Captured backward range preserves peer atoms");
    check(edited.focus !== null && a.resolvePosition(edited.focus).offset === 3, "UTF16 focus resolves");
    const beforeInvalidOffset = a.save(); rejected(() => a.captureTextRange(field("p"), 2, 3), "Surrogate-interior offset rejects"); same(a.save(), beforeInvalidOffset, "Invalid capture cannot author");
    same(initial.document.blocks[0]?.content, [{ type: "text", text: "abcd" }], "Previously published state stays unchanged");
    b.receive(a.changes()); b.receive(a.changes()); same(a.getSnapshot().document, b.getSnapshot().document, "Replica converges, duplicate receive inert");
    const reopened = restore(a); reopened.restoreHistorySelection(a.exportHistorySelection());
    const undo = applied(reopened.execute({ command: "undo", arguments: {} }));
    same(undo.document.blocks[0]?.content, [{ type: "text", text: "abXcd" }], "Reopened Undo retains peer insertion");
    check(undo.selectionIntent !== null, "History sidecar restores local selection");
    applied(reopened.execute({ command: "redo", arguments: {} })); same(reopened.getSnapshot().document, edited.document, "Reopened Redo");
    check(observed >= 2, "Notifications delivered"); checks.push("captured Unicode peer range, immutable publication, idempotent receive, reopen and selection history");

    const titleField: ModernField = { node: { document: { documentID: shared.documentID } }, name: "title" };
    applied(a.execute({ command: "replaceTitle", target: a.captureTextRange(titleField, 0, 5), arguments: { text: "東京" }, historySelection: null }));
    applied(a.execute({ command: "setAppearance", target: { document: { documentID: shared.documentID } }, arguments: { field: "fontFamily", value: "monospace" } }));
    const beforePolicy = a.save(); a.setAuthoringPolicy(["replaceTitle"]);
    const denied = a.execute({ command: "replaceText", target: a.captureTextRange(field("p"), 0, 0), arguments: { text: "blocked" } });
    check(denied.status === "unavailable" && denied.reason === "hostPolicy", "Host policy enforced"); same(a.save(), beforePolicy, "Policy does not change accepted save");
    a.setAuthoringPolicy(null); a.setComposing(true);
    check(a.execute({ command: "undo", arguments: {} }).reason === "compositionActive", "Composition blocks structural edits"); a.setComposing(false); a.endTypingGroup();
    const report: unknown[] = []; a.onListenerError = error => { report.push(error); }; const unsubscribe = a.subscribe(() => { throw new Error("UI listener failed"); });
    applied(a.execute({ command: "replaceTitle", target: a.captureTextRange(titleField, 2, 2), arguments: { text: "!" } })); unsubscribe(); check(report.length === 1, "Listener failure cannot mask accepted edit");
    checks.push("document origin title/appearance, composition and author policy, listener failure isolation");

    const heldDoc = document("adapter-held"), held = create("a", heldDoc), peer = create("b", heldDoc);
    const releaseA = held.holdRemoteChanges(), releaseB = held.holdRemoteChanges();
    applied(peer.execute({ command: "replaceText", target: peer.captureTextRange(field("p"), 4, 4), arguments: { text: "R" } }));
    const heldSave = held.save(); held.receive(peer.changes()); same(held.save(), heldSave, "Held peer not accepted"); check(held.deferredChanges().length === 1, "Held packet exported");
    const deferred = held.deferredChanges(), restoredHeld = create("c", heldDoc); restoredHeld.restoreDeferredChanges(deferred); same(restoredHeld.getSnapshot().document, peer.getSnapshot().document, "Deferred input survives host archive");
    releaseA(); releaseA(); same(held.save(), heldSave, "One nested hold remains"); releaseB(); releaseB(); same(held.getSnapshot().document, peer.getSnapshot().document, "Final release applies once"); held.retryDeferredChanges();
    checks.push("nested idempotent remote holds, deferred archive restore and release");

    const conflictDoc = document("adapter-recovery", []), x = create("x", conflictDoc), y = create("y", conflictDoc);
    const own = applied(x.execute({ command: "insertBlock", target: x.captureBoundary(), arguments: { block: paragraph("same", "X") } })).transaction!;
    applied(y.execute({ command: "insertBlock", target: y.captureBoundary(), arguments: { block: paragraph("same", "Y") } }));
    const accepted = x.save(), receipt = x.getSnapshot().syncState;
    const failure = rejected(() => x.receive(y.changes()), "Conflicting union needs recovery"); check(failure instanceof SwiftModernRecoveryError, "Recovery error typed");
    same(x.save(), accepted, "Recovery preserves accepted save"); same(x.getSnapshot().syncState, receipt, "Recovery preserves receipt");
    check(x.getSnapshot().recovery?.reason === "identityConflict", "Snapshot refreshed before recovery notification");
    const recover = restore(x, "x"); rejected(() => recover.restoreRecovery(failure.recovery), "Restored unresolved union remains recovery"); same(recover.recovery(), failure.recovery, "Recovery archive retained");
    recover.repairUndo([own]); same(recover.getSnapshot().document, y.getSnapshot().document, "Repair keeps peer birth");
    const heldConflict = restore(x, "x"), releaseConflict = heldConflict.holdRemoteChanges(); heldConflict.receive(y.changes());
    check(rejected(releaseConflict, "Release conflict throws") instanceof SwiftModernRecoveryError, "Release preserves recovery error"); releaseConflict();
    check(heldConflict.deferredChanges().length === 0 && heldConflict.recovery() !== null, "Failed release consumed once and recovery retained");
    checks.push("typed identity recovery, unchanged acceptance/receipt, archived recovery, author repair, failed release once");

    const c = create("a"), target = { ranges: [c.captureTextRange(field("p"), 1, 3)] };
    const saveBeforeCopy = c.save(), clipboard = c.copy(target); check(clipboard.version === 2 && clipboard.plainText === "bc", "Clipboard typed version and plain text"); same(c.save(), saveBeforeCopy, "Copy read only");
    const cut = c.prepareCut(target); same(c.save(), saveBeforeCopy, "Preparation non destructive");
    const failedPublish = c.finishCut(cut, false); check(failedPublish.status === "unavailable" && failedPublish.retainedClipboard?.plainText === "bc", "Failed publication retains clipboard"); same(c.save(), saveBeforeCopy, "Failed publication preserves content");
    applied(c.finishCut(cut, true)); check(c.finishCut(cut, true).status === "noop", "Cut applied once"); c.forgetCut(cut.preparationID);
    same(c.getSnapshot().document.blocks[0]?.content, [{ type: "text", text: "ad" }], "Only captured selection deleted");
    const other = create("b"); check(other.finishCut(cut, true).status === "unavailable", "Foreign preparation not applied");
    applied(c.execute({ command: "paste", target: { range: c.captureTextRange(field("p"), 1, 1) }, arguments: { clipboard } })); same(c.getSnapshot().document.blocks[0]?.content, [{ type: "text", text: "abcd" }], "Retained rich paste");
    const cancel = c.prepareCut({ ranges: [c.captureTextRange(field("p"), 0, 1)] }); c.cancelCut(cancel.preparationID); check(c.finishCut(cancel, true).reason === "cutCancelled", "Cancelled cut inert"); c.forgetCut(cancel.preparationID);
    checks.push("typed readonly copy, explicit publication cut, foreign/cancelled/duplicate outcomes and retained paste");

    const image = create("a", document("adapter-provider", [{ id: "image", type: "image", src: "asset://pending", alt: "old" }]));
    const request = image.beginAsyncBlock(node("image"), "provider"); image.failAsyncBlock(request, "retry later");
    check(image.asyncRequests().some(record => record.status === "failed"), "Provider failure local");
    const pending = image.beginAsyncBlock(node("image"), "pending-provider");
    const providerArchive = image.exportAsyncRequests();
    const imageReopen = restore(image);
    check(imageReopen.execute({ command: "completeAsyncBlock", target: pending, arguments: { metadata: { alt: "late" } } }).status === "unavailable", "Accepted save does not restore local provider invocation");
    imageReopen.restoreAsyncRequests(providerArchive); check(imageReopen.getSnapshot().document.blocks[0]?.alt === "old", "Explicit local archive restore does not author metadata");
    const newRequest = imageReopen.beginAsyncBlock(node("image"), "restarted-provider");
    check(imageReopen.execute({ command: "completeAsyncBlock", target: pending, arguments: { metadata: { alt: "late" } } }).status === "unavailable", "New invocation invalidates old generation");
    applied(imageReopen.execute({ command: "completeAsyncBlock", target: newRequest, arguments: { metadata: { alt: "ready" } } }));
    check(imageReopen.getSnapshot().document.blocks[0]?.alt === "ready", "Explicit completion authors metadata"); imageReopen.cancelAsyncBlock(newRequest); imageReopen.forgetAsyncBlock(newRequest);
    checks.push("typed local provider archive, inert save reopen, explicit archive restore, invocation generation invalidation and cleanup");

    const structural = create("a");
    applied(structural.execute({ command: "format", target: structural.captureTextRange(field("p"), 0, 2), arguments: { markType: "bold", mark: { type: "bold" } } }));
    const semanticTarget = { range: structural.captureTextRange(field("p"), 0, 2) };
    applied(structural.execute({ command: "setSemanticColor", target: semanticTarget, arguments: { kind: "ink", role: "blue" } }));
    same(structural.semanticState(semanticTarget, "ink"), { role: { _0: "blue" } }, "Semantic state discriminant");
    applied(structural.execute({ command: "setLink", target: structural.captureTextRange(field("p"), 0, 2), arguments: { href: "https://example.org" } }));
    applied(structural.execute({ command: "convertBlock", target: structural.captureTextRange(field("p"), 0, 0), arguments: { type: "heading", level: 2 } }));
    applied(structural.execute({ command: "convertBlock", target: structural.captureTextRange(field("p"), 0, 0), arguments: { type: "paragraph" } }));
    const split = applied(structural.execute({ command: "splitBlock", target: structural.captureTextRange(field("p"), 2, 2), arguments: { newBlockID: "q" } }));
    check(split.focus !== null, "Split destination caret");
    applied(structural.execute({ command: "mergeBlocks", target: structural.captureNodes([node("p"), split.focus.field.node]), arguments: {} }));
    applied(structural.execute({ command: "softBreak", target: structural.captureTextRange(field("p"), 2, 2), arguments: {} }));
    const duplicate = applied(structural.execute({ command: "duplicate", target: { selection: structural.captureNodes([node("p")]), boundary: structural.captureBoundary({ field: "blocks" }, node("p")) }, arguments: { newBlockIDs: ["copy"] } }));
    check(duplicate.selectionIntent !== null && "nodes" in duplicate.selectionIntent, "Duplicate selected origins");
    const duplicatedNodes = duplicate.selectionIntent.nodes._0;
    applied(structural.execute({ command: "move", target: { selection: duplicatedNodes, boundary: structural.captureBoundary() }, arguments: {} }));
    applied(structural.execute({ command: "delete", target: { nodes: duplicatedNodes, ranges: [] }, arguments: {} }));
    const columns = applied(structural.execute({ command: "createColumns", target: { boundary: structural.captureBoundary() }, arguments: { layout: { id: "layout", type: "columns", splitBasisPoints: 5000, columns: [{ id: "left", children: [] }, { id: "right", children: [] }] } } }));
    check(columns.selectionIntent !== null && "nodes" in columns.selectionIntent, "Column origin returned"); const layout = columns.selectionIntent.nodes._0.nodes[0]!;
    applied(structural.execute({ command: "resizeColumns", target: { layout }, arguments: { splitBasisPoints: 3000 } }));
    applied(structural.execute({ command: "removeColumns", target: { layout }, arguments: {} }));
    checks.push("typed format, semantic color/state, link, conversion, split/merge, soft break, duplicate/move/delete and columns");

    const list = create("a", document("adapter-list", [{ id: "list", type: "list", style: "unordered", items: [{ id: "i1", content: [{ type: "text", text: "one" }] }, { id: "i2", content: [{ type: "text", text: "two" }] }] }]));
    const second = node("list", ["items", "i2"]);
    applied(list.execute({ command: "listStructure", target: { selection: list.captureListNodes([second]) }, arguments: { action: "indent" } }));
    applied(list.execute({ command: "listStructure", target: { selection: list.captureListNodes([second]) }, arguments: { action: "outdent" } }));
    applied(list.execute({ command: "listStructure", target: { selection: list.captureListNodes([node("list")]) }, arguments: { action: "setStyle", style: "todo" } }));
    applied(list.execute({ command: "listStructure", target: { selection: list.captureListNodes([second]) }, arguments: { action: "setChecked", checked: true } }));
    list.setListPolicy(["reorder"]);
    check(list.execute({ command: "listStructure", target: { selection: list.captureListNodes([second]) }, arguments: { action: "outdent" } }).reason === "hostPolicy", "List action policy");
    applied(list.execute({ command: "listStructure", target: { selection: list.captureListNodes([second]), boundary: list.captureListBoundary({ owner: node("list"), field: "items" }) }, arguments: { action: "reorder" } }));
    check(list.captureLocalNodes([second]).nodes.length === 1, "Local item target typed"); checks.push("all five list actions, list policy and captured local item nodes");

    for (const fixture of fixtures) {
      const f = create("fixture", fixture.document); same(f.getSnapshot().document, fixture.document, `${fixture.name}: whole independent fixture round trip`);
      const reopenedFixture = restore(f, "fixture"); same(reopenedFixture.getSnapshot().document, fixture.document, `${fixture.name}: accepted save restore`);
      f.close(); reopenedFixture.close();
    }
    checks.push("independent complete document round trips");

    const cutover = new SwiftModernCutover(transport), bytes = new TextEncoder().encode(JSON.stringify([paragraph("legacy", "old")]));
    const base64 = (value: Uint8Array) => btoa(Array.from(value, byte => String.fromCharCode(byte)).join(""));
    const rawArchive = { version: 1 as const, documentID: "adapter-cutover", epoch: "new", source: { document: { format: "blockArray" as const, bytes: base64(bytes) } }, originals: [base64(new TextEncoder().encode("host original"))] };
    const encoded = new TextEncoder().encode(JSON.stringify(rawArchive)), upload = cutover.begin(encoded.length);
    cutover.append(upload.archiveID, 0, base64(encoded)); const plan = cutover.prepareUploaded(upload.archiveID);
    check(plan.status === "prepared", "Cutover prepared");
    rejected(() => SwiftModernSession.fromCutover(transport, plan.archiveID, { actorID: "a", oldWritersStopped: true, archivePersisted: true, resetUndoAcknowledged: true }), "Unverified readback cannot create");
    const chunk = cutover.bytes(plan.archiveID, 0, plan.byteCount); cutover.verifyReadback(plan.archiveID, 0, chunk.bytes);
    const migrated = SwiftModernSession.fromCutover(transport, plan.archiveID, { actorID: "a", oldWritersStopped: true, archivePersisted: true, resetUndoAcknowledged: true }); sessions.push(migrated.session);
    check(migrated.session.getSnapshot().syncState.received.length === 0 && !migrated.session.getSnapshot().canUndo, "Fresh epoch has no old history"); check(migrated.originMapping.length === 1, "Origin mapping typed"); cutover.forget(plan.archiveID);
    const unavailable = cutover.prepare({ ...rawArchive, source: { document: { format: "blockArray", bytes: base64(new TextEncoder().encode(JSON.stringify([{ id: "file", type: "file", url: "legacy-file", name: "old" }]))) } } });
    check(unavailable.status === "unavailable", "Incompatible legacy data stays archived"); cutover.bytes(unavailable.archiveID, 0, 1); cutover.forget(unavailable.archiveID);
    const oldHandle = crypto.randomUUID();
    try {
      transport.call({ command: "create", session: oldHandle, documentID: "adapter-remap", actorID: "old", collaborationVersion: 2, blocks: [{ id: "p", type: "paragraph", content: [{ type: "text", text: "old", marks: [] }] }] });
      const identity = transport.call<ModernNodeID>({ command: "node", session: oldHandle, address: { blockID: "p", path: [] } });
      const oldPosition = transport.call<SwiftTextPosition>({ command: "position", session: oldHandle, address: { blockID: "p", path: ["content"], identity }, offset: 1, affinity: "before" });
      const oldSave = base64(new TextEncoder().encode(JSON.stringify(transport.call({ command: "save", session: oldHandle }))));
      const mappedPlan = cutover.prepare({ version: 1, documentID: "adapter-remap", epoch: "mapped", originals: [], source: { session: { acceptedSnapshot: oldSave, reconciledSnapshot: oldSave, unacknowledged: [] } } });
      check(mappedPlan.status === "prepared", "Old session prepared for remapping");
      const mapped = cutover.remapPosition(mappedPlan.archiveID, "text", oldPosition);
      const archiveBytes = cutover.bytes(mappedPlan.archiveID, 0, mappedPlan.byteCount); cutover.verifyReadback(mappedPlan.archiveID, 0, archiveBytes.bytes);
      const newSession = SwiftModernSession.fromCutover(transport, mappedPlan.archiveID, { actorID: "a", oldWritersStopped: true, archivePersisted: true, resetUndoAcknowledged: true }).session; sessions.push(newSession);
      check(newSession.resolvePosition(mapped).offset === 1 && mapped.epoch === "mapped", "Typed old position resolves in fresh epoch"); cutover.forget(mappedPlan.archiveID);
    } finally { transport.call({ command: "close", session: oldHandle }); }
    checks.push("chunked cutover, mandatory readback, fresh history, origin map and incompatible archival export");

    const batchDoc = document("adapter-batch", [
      { id: "table", type: "table", rows: [{ id: "row", cells: [{ id: "cell", content: [] }] }] },
      { id: "image", type: "image", src: "asset://pending", caption: [] },
      { id: "code", type: "code", code: "\t😀\n  literal" }, paragraph("shortcut", "# "),
    ]);
    const batch = create("batch", batchDoc), tableNode = batch.node({ blockID: "table", path: [] }), rowNode = batch.node({ blockID: "table", path: ["rows", "row"] });
    check(batch.insertionCatalog("two")[0]?.id === "columns", "Shared insertion vocabulary through typed bridge");
    applied(batch.execute({ command: "tableStructure", target: batch.captureTableTarget(tableNode, rowNode), arguments: { action: "insertRow", newIDs: ["new-row", "new-cell"] } }));
    same((batch.getSnapshot().document.blocks[0].rows as readonly ModernObject[]).map(row => row.id), ["row", "new-row"], "Independent table insertion expectation");
    applied(batch.execute({ command: "mediaProperties", target: batch.captureMediaTarget(batch.node({ blockID: "image", path: [] })), arguments: { metadata: { width: 320, height: 160 } } }));
    check(batch.getSnapshot().document.blocks[1].width === 320 && batch.getSnapshot().document.blocks[1].height === 160, "Direct checked media dimensions");
    applied(batch.execute({ command: "codeProperties", target: batch.captureCodeTarget(batch.node({ blockID: "code", path: [] })), arguments: { language: "swift" } }));
    check(batch.getSnapshot().document.blocks[2].code === "\t😀\n  literal" && batch.getSnapshot().document.blocks[2].language === "swift", "Code metadata retains literal text");
    const shortcutField = batch.field(batch.node({ blockID: "shortcut", path: [] }));
    applied(batch.execute({ command: "typingShortcut", target: batch.captureTextRange(shortcutField, 2, 2), arguments: {} }));
    check(batch.getSnapshot().document.blocks[3].type === "heading" && (batch.getSnapshot().document.blocks[3].content as readonly unknown[]).length === 0, "Shared heading shortcut consumes captured delimiter");
    const foreign = create("foreign", document("foreign", [{ id: "image", type: "image", src: "asset://pending" }]));
    rejected(() => foreign.execute({ command: "mediaProperties", target: batch.captureMediaTarget(batch.node({ blockID: "image", path: [] })), arguments: { metadata: { alt: "wrong document" } } }), "Media capture must include original document scope");

    const closedHold = create("closed"), releaseClosed = closedHold.holdRemoteChanges(); closedHold.close(); releaseClosed(); releaseClosed();
    for (const s of sessions) s.close(); rejected(() => a.save(), "Closed handle rejects access"); checks.push("closed session lifecycle");
    const commands = sourceTransport.call<{ commands: readonly string[] }>({ command: "modernCapabilities" }).commands;
    for (const command of commands) check(appliedCommands.has(command), `${command}: actual applied consumer coverage required`);
    return { checks, fixtures: fixtures.length, appliedCommands: [...appliedCommands].sort() };
  } finally { for (const s of sessions) s.close(); }
}

// Compile this consumer with tsconfig.modern-tests.json. Rejected pairings should
// remain rejected even when the facade changes; no runtime operation is needed.
export function typeContract(session: SwiftModernSession, scope: ModernScope): void {
  const target = session.captureTextRange(field("p"), 0, 1);
  // @ts-expect-error Appearance preset must correspond to its field.
  session.execute({ command: "setAppearance", target: { document: { documentID: scope.documentID } }, arguments: { field: "fontFamily", value: "large" } });
  // @ts-expect-error Opaque appearance extension data does not become an authorable register.
  session.execute({ command: "setAppearance", target: { document: { documentID: scope.documentID } }, arguments: { field: "consumer", value: "overwrite" } });
  // @ts-expect-error Structural insertion requires a captured boundary.
  session.execute({ command: "insertBlock", target, arguments: { block: paragraph("p") } });
  // @ts-expect-error Undo cannot override the history selection.
  session.execute({ command: "undo", arguments: {}, historySelection: null });
  // @ts-expect-error Paste cannot combine text and collection targets.
  session.execute({ command: "paste", target: { range: target, boundary: session.captureBoundary() }, arguments: { clipboard: null } });
  const value: ModernJSON = session.getSnapshot().document.blocks; void value;
}
