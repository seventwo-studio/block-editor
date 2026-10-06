/** Protocol 7 contracts. Payloads are validated and authored by the shared core;
 * hosts retain opaque document metadata and transport change bodies unchanged. */
import type { SwiftTextPosition, SwiftWritingPosition } from "./swift.js";
export type ModernJSON = null | boolean | number | string | readonly ModernJSON[] | { readonly [key: string]: ModernJSON };
export type ModernObject = { readonly [key: string]: ModernJSON };
export interface ModernChangeID { readonly actor: string; readonly counter: number }
export interface ModernElementID { readonly change: ModernChangeID; readonly index: number }
export type ModernNodeID = { readonly document: { readonly documentID: string } }
  | { readonly baseline: { readonly blockID: string; readonly path: readonly string[] } }
  | { readonly inserted: { readonly creation: ModernElementID; readonly path: readonly string[] } };
export type ModernCollection = { readonly field: "blocks"; readonly owner?: never }
  | { readonly owner: ModernNodeID; readonly field: "children" | "columns" | "items" | "rows" | "cells" };
export type ModernPlacementID = { readonly initial: { readonly _0: ModernNodeID } }
  | { readonly edit: { readonly _0: ModernElementID } }
  | { readonly role: { readonly owner: ModernNodeID; readonly node: ModernNodeID } }
  | { readonly columnRoute: { readonly layout: ModernNodeID; readonly slot: ModernElementID; readonly node: ModernNodeID } };
export interface ModernField { readonly node: ModernNodeID; readonly name: string }
export interface ModernPosition {
  readonly documentID: string; readonly epoch: string; readonly field: ModernField;
  readonly affinity: "before" | "after";
  readonly anchor?: { readonly origin: ModernField; readonly element: ModernElementID };
  readonly intraAtomOffset?: number;
}
export interface ModernResolvedPosition { readonly address: { readonly blockID: string; readonly path: readonly string[]; readonly identity?: ModernNodeID }; readonly offset: number }
export interface ModernRange { readonly start: ModernPosition; readonly end: ModernPosition }
export interface ModernTextRange extends ModernRange { readonly observed: readonly ModernChangeID[] }
export interface ModernScope { readonly documentID: string; readonly epoch: string }
export interface ModernBoundary extends ModernScope { readonly collection: ModernCollection; readonly after?: ModernPlacementID; readonly observed: readonly ModernChangeID[] }
export interface ModernNodes extends ModernScope { readonly nodes: readonly ModernNodeID[]; readonly observed: readonly ModernChangeID[] }
export interface ModernDeleteTarget { readonly nodes?: ModernNodes; readonly ranges: readonly ModernTextRange[] }
export type ModernFocusIntent = { readonly text: { readonly _0: ModernPosition } } | { readonly nodes: { readonly _0: ModernNodes } } | { readonly insertion: { readonly _0: ModernBoundary } };
export type ModernSelectionIntent = { readonly text: { readonly _0: ModernRange } } | { readonly nodes: { readonly _0: ModernNodes } } | { readonly mixed: { readonly _0: ModernDeleteTarget } };
export interface ModernLocalSelection extends ModernScope { readonly observed: readonly ModernChangeID[]; readonly focus?: ModernFocusIntent; readonly selection?: ModernSelectionIntent }
export interface ModernAppearancePresets { readonly fontFamily: "sans" | "serif" | "monospace"; readonly fontSize: "small" | "default" | "large"; readonly pageWidth: "readable" | "wide" }
export interface ModernAppearance extends ModernAppearancePresets { readonly [key: string]: ModernJSON }
export interface ModernDocument {
  readonly format: "seventwo.block-editor.document"; readonly formatVersion: 1; readonly documentID: string;
  readonly title: string; readonly appearance: ModernAppearance; readonly blocks: readonly ModernObject[];
  readonly [key: string]: ModernJSON | ModernAppearance;
}
export interface ModernBatch extends ModernScope { readonly version: 7; readonly baseline: ModernDocument; readonly changes: readonly ModernObject[] }
export interface ModernReceipt extends ModernScope { readonly version: 7; readonly received: readonly ModernChangeID[] }
export interface ModernRecovery { readonly reason: "identityConflict" | "schemaConstraint"; readonly batch: ModernBatch }
export interface ModernSnapshot { readonly version: 7; readonly document: ModernDocument; readonly syncState: ModernReceipt; readonly canUndo: boolean; readonly canRedo: boolean; readonly recovery: ModernRecovery | null }
export class SwiftModernRecoveryError extends Error {
  readonly recovery: ModernRecovery;
  constructor(recovery: ModernRecovery) { super("Modern editor recovery required"); this.name = "SwiftModernRecoveryError"; this.recovery = owned(recovery); }
}
export interface ModernClipboard {
  readonly version: 2; readonly collaborationVersion: 7; readonly plainText: string;
  readonly parts: readonly ({ readonly inline: { readonly _0: readonly ModernObject[] } } | { readonly node: { readonly value: ModernObject; readonly kind: "block" | "item" | "row" | "cell" } })[];
}
export interface ModernPastePolicy { readonly allowedBlockTypes?: readonly string[]; readonly allowedMarkTypes?: readonly string[]; readonly allowAssetMetadata: boolean }
export type ModernPasteTarget = { readonly range: ModernTextRange; readonly boundary?: never; readonly selection?: never } | { readonly boundary: ModernBoundary; readonly selection?: ModernDeleteTarget; readonly range?: never };
export interface ModernColumnTarget { readonly layout: ModernNodeID; readonly caret?: ModernPosition }
export type ModernCreateColumnsTarget = ({ readonly selection: ModernNodes; readonly boundary?: never } | { readonly boundary: ModernBoundary; readonly selection?: never }) & { readonly caret?: ModernPosition };
export type ModernSemanticTarget = ({ readonly range: ModernTextRange; readonly nodes?: never; readonly caret?: never } | { readonly nodes: ModernNodes; readonly range?: never; readonly caret?: ModernPosition });
export type ModernSemanticKind = "ink" | "fill";
export type ModernSemanticRole = "neutral" | "green" | "blue" | "purple" | "amber" | "red";
export type ModernSemanticState = { readonly inherited: Record<string, never> } | { readonly mixed: Record<string, never> } | { readonly role: { readonly _0: ModernSemanticRole } };
export type ModernTableAction = "insertRow" | "removeRow" | "insertColumn" | "removeColumn" | "setHeader";
export interface ModernTableTarget extends ModernScope { readonly table: ModernNodeID; readonly row?: ModernNodeID; readonly cell?: ModernNodeID; readonly observed: readonly ModernChangeID[] }
export interface ModernMediaTarget extends ModernScope { readonly origin: ModernAsyncTarget["origin"] }
export interface ModernInsertionDescriptor { readonly id: string; readonly title: string; readonly description: string; readonly blockType: string; readonly requiresHost: boolean }
export interface ModernAvailability { readonly command: string; readonly available: boolean; readonly reason?: string }
export type ModernListAction = "indent" | "outdent" | "reorder" | "setStyle" | "setChecked";
export interface ModernListTarget { readonly selection: ModernNodes; readonly caret?: ModernPosition; readonly boundary?: ModernBoundary }
export interface ModernAsyncTarget extends ModernScope {
  readonly requestID: string; readonly generation: number;
  readonly origin: { readonly node: ModernNodeID; readonly kind: "image" | "file" | "embed"; readonly source: string; readonly observed: readonly ModernChangeID[] };
}
export interface ModernAsyncRecord { readonly target: ModernAsyncTarget; readonly status: "pending" | "retained" | "failed" | "cancelled" | "applied"; readonly result?: ModernObject; readonly reason?: string; readonly receipt?: readonly ModernChangeID[] }
export interface ModernAsyncArchive extends ModernScope { readonly version: 1; readonly generation: number; readonly requests: readonly ModernAsyncRecord[] }
export interface ModernHistorySelectionArchive extends ModernScope {
  readonly version: 1; readonly actorID: string; readonly current?: ModernLocalSelection;
  readonly records: readonly { readonly edits: readonly ModernChangeID[]; readonly before?: ModernLocalSelection; readonly after?: ModernLocalSelection }[];
}
type EmptyArguments = Record<string, never>;
type Command<C extends string, T, A> = { readonly command: C; readonly target: T; readonly arguments: A; readonly historySelection?: ModernLocalSelection | null };
/** Discriminated authoring requests keep command, captured target and arguments together. */
export type ModernAuthorCommand =
  | Command<"replaceText" | "replaceTitle", ModernTextRange, { readonly text: string; readonly typingGroup?: string }>
  | Command<"setAppearance", { readonly document: { readonly documentID: string } }, { [F in keyof ModernAppearancePresets]: { readonly field: F; readonly value: ModernAppearancePresets[F] } }[keyof ModernAppearancePresets]>
  | Command<"format", ModernTextRange | { readonly ranges: readonly ModernTextRange[] }, { readonly markType: string; readonly mark: ModernObject | null }>
  | Command<"insertBlock", ModernBoundary, { readonly block: ModernObject }>
  | Command<"duplicate", { readonly selection: ModernNodes; readonly boundary: ModernBoundary }, { readonly newBlockIDs: readonly string[] }>
  | Command<"paste", ModernPasteTarget, { readonly clipboard: ModernClipboard | null; readonly mode?: "rich" | "flattenedColumns" | "plainText"; readonly newIDs?: readonly string[]; readonly policy?: ModernPastePolicy; readonly focusInserted?: boolean }>
  | Command<"move", { readonly selection: ModernNodes; readonly boundary: ModernBoundary; readonly caret?: ModernPosition }, EmptyArguments>
  | Command<"delete", ModernDeleteTarget, EmptyArguments>
  | Command<"createColumns", ModernCreateColumnsTarget, { readonly layout: ModernObject }>
  | Command<"removeColumns", ModernColumnTarget, EmptyArguments>
  | Command<"resizeColumns", ModernColumnTarget, { readonly splitBasisPoints: number }>
  | Command<"convertBlock", ModernTextRange | ModernNodes, { readonly type: "paragraph" | "heading" | "quote" | "callout" | "list" | "code"; readonly level?: 1 | 2 | 3; readonly style?: "ordered" | "unordered" | "todo"; readonly variant?: "info" | "warning" | "error" | "success" }>
  | Command<"softBreak" | "typingShortcut", ModernTextRange, EmptyArguments>
  | Command<"splitBlock", ModernTextRange, { readonly newBlockID: string }>
  | Command<"codeProperties", ModernCodeTarget, { readonly language: string | null }>
  | Command<"mergeBlocks", ModernNodes, EmptyArguments>
  | Command<"tableStructure", ModernTableTarget, { readonly action: ModernTableAction; readonly newIDs?: readonly string[]; readonly header?: boolean }>
  | Command<"mediaProperties", ModernMediaTarget, { readonly metadata: ModernObject }>
  | Command<"listStructure", ModernListTarget, { readonly action: "indent" | "outdent" | "reorder" } | { readonly action: "setStyle"; readonly style: "ordered" | "unordered" | "todo" } | { readonly action: "setChecked"; readonly checked: boolean }>
  | Command<"setSemanticColor", ModernSemanticTarget, { readonly kind: ModernSemanticKind; readonly role: ModernSemanticRole | null }>
  | Command<"setLink", ModernTextRange, { readonly href: string | null; readonly label?: string }>
  | Command<"completeAsyncBlock", ModernAsyncTarget, { readonly metadata: ModernObject }>
  | { readonly command: "undo" | "redo"; readonly arguments: EmptyArguments; readonly target?: never; readonly historySelection?: never };
export type ModernCommandName = ModernAuthorCommand["command"];
export interface ModernResult extends ModernSnapshot {
  readonly status: "applied" | "noop" | "unavailable" | "recoveryRequired"; readonly transaction: ModernChangeID | null;
  readonly focus: ModernPosition | null; readonly selection: ModernRange | ModernNodes | ModernDeleteTarget | null;
  readonly focusIntent: ModernFocusIntent | null; readonly selectionIntent: ModernSelectionIntent | null;
  readonly reason?: string | null; readonly retainedClipboard?: ModernClipboard | null; readonly retainedResult?: ModernObject | null;
}
export interface ModernCodeTarget extends ModernScope { readonly node: ModernNodeID; readonly observed: readonly ModernChangeID[] }
export interface ModernCapabilities {
  readonly protocolVersion: 7; readonly format: ModernDocument["format"]; readonly formatVersion: 1;
  readonly commands: readonly ModernCommandName[]; readonly cutoverToModern: true; readonly clipboardVersion: 2;
  readonly localHistorySelectionVersion: 1; readonly canCopy: boolean; readonly canCut: boolean;
  readonly allowedBlockTypes: readonly string[] | null; readonly allowedMarkTypes: readonly string[] | null;
  readonly codeLanguages: readonly string[]; readonly tableActions: readonly ModernTableAction[]; readonly listActions: readonly ModernListAction[]; readonly asyncKinds: readonly ("image" | "file" | "embed")[];
  readonly canUndo?: boolean; readonly canRedo?: boolean; readonly isComposing?: boolean; readonly recoveryRequired?: boolean;
}
export interface ModernCutPreparation extends ModernScope { readonly preparationID: string; readonly target: ModernDeleteTarget; readonly clipboard: ModernClipboard }
export interface ModernPolicy { readonly allowedCommands?: readonly ModernCommandName[]; readonly allowedListActions?: readonly ModernListAction[]; readonly allowedBlockTypes?: readonly string[]; readonly allowedMarkTypes?: readonly string[] }
/** A synchronous, serialized bridge with newly owned decoded values on each call.
 * SwiftEditorRuntime implements this contract for WASM. No network/provider work is implicit. */
export interface ModernTransport { call<T>(request: Record<string, unknown>): T }

// Iterative ownership protects opaque metadata too, without serializing whole archives again.
function owned<T>(value: T): T {
  const pending: object[] = value !== null && typeof value === "object" ? [value] : [];
  const seen = new Set<object>();
  while (pending.length) {
    const item = pending.pop()!; if (seen.has(item)) continue; seen.add(item);
    for (const child of Object.values(item)) if (child !== null && typeof child === "object") pending.push(child);
    Object.freeze(item);
  }
  return value;
}

/** Explicit modern session. Command outcomes carry local focus intent; the host decides
 * when to apply it. Persist recovery, deferred input and local sidecars separately from save(). */
export class SwiftModernSession {
  private closed = false;
  private listeners = new Set<() => void>();
  private constructor(private readonly transport: ModernTransport, private readonly handle: string, private snapshot: ModernSnapshot) { this.snapshot = owned(snapshot); }
  static create(transport: ModernTransport, options: ModernScope & ModernPolicy & { readonly actorID: string; readonly document: ModernDocument }): SwiftModernSession {
    const handle = crypto.randomUUID();
    return new SwiftModernSession(transport, handle, transport.call({ command: "createModern", session: handle, collaborationVersion: 7, ...options }));
  }
  static restore(transport: ModernTransport, snapshot: ModernObject, actorID: string, policy: ModernPolicy = {}): SwiftModernSession {
    const handle = crypto.randomUUID();
    return new SwiftModernSession(transport, handle, transport.call({ command: "restoreModern", session: handle, snapshot, actorID, ...policy }));
  }
  static fromCutover(transport: ModernTransport, archiveID: string, options: { readonly actorID: string; readonly oldWritersStopped: true; readonly archivePersisted: true; readonly resetUndoAcknowledged: true }): { readonly session: SwiftModernSession; readonly originMapping: readonly ModernCutoverIdentity[] } {
    const handle = crypto.randomUUID();
    const value = transport.call<ModernSnapshot & { originMapping: readonly ModernCutoverIdentity[] }>({ command: "cutoverToModern", session: handle, archiveID, ...options });
    return { session: new SwiftModernSession(transport, handle, value), originMapping: owned(value.originMapping) };
  }
  getSnapshot = (): ModernSnapshot => this.snapshot;
  subscribe = (listener: () => void): (() => void) => { this.assertOpen(); this.listeners.add(listener); return () => this.listeners.delete(listener); };
  /** Listener failures occur after accepted publication and never turn an applied edit
   * into an apparent command failure. Hosts may set this handler to report UI errors. */
  onListenerError: (error: unknown) => void = error => { queueMicrotask(() => { throw error; }); };
  private assertOpen(): void { if (this.closed) throw new Error("Modern session is closed"); }
  private publish(value: ModernSnapshot): void {
    this.snapshot = owned(value);
    for (const listener of [...this.listeners]) {
      try { listener(); } catch (error) { try { this.onListenerError(error); } catch (reportError) { queueMicrotask(() => { throw reportError; }); } }
    }
  }
  private call<T>(command: string, args: Record<string, unknown> = {}): T {
    this.assertOpen();
    try { return owned(this.transport.call<T>({ command, session: this.handle, ...args })); }
    catch (error) {
      if (error instanceof SwiftModernRecoveryError) this.publish(this.transport.call<ModernSnapshot>({ command: "modernSnapshot", session: this.handle }));
      throw error;
    }
  }
  private update(command: string, args: Record<string, unknown> = {}): void { this.publish(this.call<ModernSnapshot>(command, args)); }
  insertionValue(descriptorID: string, id: string, childIDs: readonly string[] = []): ModernObject { return this.call("modernInsertionValue", { descriptorID, id, childIDs }); }
  insertionCatalog(query = ""): readonly ModernInsertionDescriptor[] { return this.call("modernInsertionCatalog", { query }); }
  availability(name: ModernCommandName): ModernAvailability { return this.call("modernAvailability", { name }); }
  captureTableTarget(table: ModernNodeID, row?: ModernNodeID, cell?: ModernNodeID): ModernTableTarget { return this.call("modernCaptureTableTarget", { table, ...(row ? { row } : {}), ...(cell ? { cell } : {}) }); }
  captureCodeTarget(node: ModernNodeID): ModernCodeTarget { return this.call("modernCaptureCodeTarget", { node }); }
  captureMediaTarget(node: ModernNodeID): ModernMediaTarget { return this.call("modernCaptureMediaTarget", { node }); }
  retainAsyncResult(target: ModernAsyncTarget, metadata: ModernObject, reason = "awaitingPersistence"): void { this.update("modernRetainAsyncResult", { target, metadata, reason }); }
  capabilities(): ModernCapabilities { return this.call("modernCapabilities"); }
  execute(command: ModernAuthorCommand): ModernResult {
    const scope = this.snapshot.syncState;
    const result = this.call<ModernResult>("modernCommand", { request: { documentID: scope.documentID, epoch: scope.epoch, ...command } });
    this.publish(result); return result;
  }
  save(): ModernObject { return this.call("modernSave"); }
  changes(since?: ModernReceipt): ModernBatch { return this.call("modernChanges", since === undefined ? {} : { since }); }
  receive(batch: ModernBatch): void { this.update("modernReceive", { batch }); }
  recovery(): ModernRecovery | null { return this.call("modernRecovery"); }
  restoreRecovery(recovery: ModernRecovery): void { this.update("modernRestoreRecovery", { recovery }); }
  repairUndo(targets: readonly ModernChangeID[]): void { this.update("modernRepairUndo", { targets }); }
  repairRedo(targets: readonly ModernChangeID[]): void { this.update("modernRepairRedo", { targets }); }
  node(address: { readonly blockID: string; readonly path: readonly string[] }): ModernNodeID { return this.call("modernNode", { address }); }
  nodes(collection: ModernCollection = { field: "blocks" }): readonly ModernNodeID[] { return this.call("modernNodes", { collection }); }
  field(node: ModernNodeID, name = "content"): ModernField { return this.call("modernField", { node, name }); }
  text(field: ModernField): string { return this.call("modernText", { field }); }
  logicalFields(collapsed: readonly ModernNodeID[] = [], includingTitle = true): readonly ModernField[] { return this.call("modernLogicalFields", { collapsed, includingTitle }); }
  parentCollection(node: ModernNodeID): ModernCollection { return this.call("modernParentCollection", { node }); }
  captureTextSpan(start: ModernPosition, end: ModernPosition, collapsed: readonly ModernNodeID[] = []): readonly ModernTextRange[] { return this.call("modernCaptureTextSpan", { start, end, collapsed }); }
  position(field: ModernField, offset: number, affinity: ModernPosition["affinity"] = "before"): ModernPosition { return this.call("modernPosition", { field, offset, affinity }); }
  resolvePosition(position: ModernPosition): ModernResolvedPosition { return this.call("modernResolvePosition", { position }); }
  captureTextRange(field: ModernField, start: number, end: number): ModernTextRange { return this.call("modernCaptureTextRange", { field, start, end }); }
  captureBoundary(collection: ModernCollection = { field: "blocks" }, after?: ModernNodeID): ModernBoundary { return this.call("modernCaptureBoundary", { collection, after }); }
  capturePasteBoundary(collection: ModernCollection = { field: "blocks" }, after?: ModernNodeID): ModernBoundary { return this.call("modernCapturePasteBoundary", { collection, after }); }
  captureListBoundary(collection: ModernCollection, after?: ModernNodeID): ModernBoundary { return this.call("modernCaptureListBoundary", { collection, after }); }
  captureNodes(nodes: readonly ModernNodeID[]): ModernNodes { return this.call("modernCaptureNodes", { nodes }); }
  captureListNodes(nodes: readonly ModernNodeID[]): ModernNodes { return this.call("modernCaptureListNodes", { nodes }); }
  captureLocalNodes(nodes: readonly ModernNodeID[]): ModernNodes { return this.call("modernCaptureLocalNodes", { nodes }); }
  clipboard(text: string, mode: "plain" | "multiline" | "markdown" = "plain"): ModernClipboard { return this.call("modernClipboard", { text, mode }); }
  clipboardFromJSON(encoded: string): ModernClipboard { return this.call("modernClipboard", { encoded }); }
  clipboardParts(parts: readonly ModernObject[]): ModernClipboard { return this.call("modernClipboard", { parts }); }
  copy(target: ModernDeleteTarget): ModernClipboard { return this.call("modernCopy", { target }); }
  prepareCut(target: ModernDeleteTarget): ModernCutPreparation { return this.call("modernPrepareCut", { target }); }
  /** Call only after the host's clipboard publication succeeds or fails. No deletion
   * occurs at preparation. The core binds preparationID to this live session. */
  finishCut(preparation: ModernCutPreparation, published: boolean): ModernResult {
    const { preparationID, documentID, epoch } = preparation;
    const result = this.call<ModernResult>("modernFinishCut", { preparationID, documentID, epoch, published });
    this.publish(result); return result;
  }
  cancelCut(preparationID: string): void { this.update("modernCancelCut", { preparationID }); }
  forgetCut(preparationID: string): void { this.update("modernForgetCut", { preparationID }); }
  markState(range: ModernTextRange | readonly ModernTextRange[], type: string): "on" | "off" | "mixed" { return this.call("modernMarkState", Array.isArray(range) ? { ranges: range, type } : { range, type }); }
  semanticState(target: ModernSemanticTarget, kind: ModernSemanticKind): ModernSemanticState { return this.call("modernSemanticState", { target, kind }); }
  beginAsyncBlock(node: ModernNodeID, requestID: string): ModernAsyncTarget { return this.call("modernBeginAsyncBlock", { node, requestID }); }
  asyncRequests(): readonly ModernAsyncRecord[] { return this.call("modernAsyncRequests"); }
  exportAsyncRequests(): ModernAsyncArchive { return this.call("modernExportAsyncRequests"); }
  restoreAsyncRequests(archive: ModernAsyncArchive): void { this.update("modernRestoreAsyncRequests", { archive }); }
  cancelAsyncBlock(target: ModernAsyncTarget): void { this.update("modernCancelAsyncBlock", { target }); }
  forgetAsyncBlock(target: ModernAsyncTarget): void { this.update("modernForgetAsyncBlock", { target }); }
  failAsyncBlock(target: ModernAsyncTarget, reason: string): void { this.update("modernFailAsyncBlock", { target, reason }); }
  setComposing(active: boolean): void { this.update("modernComposition", { active }); }
  setAuthoringPolicy(allowedCommands: readonly ModernCommandName[] | null): void { this.update("modernSetAuthoringPolicy", { allowedCommands }); }
  setContentPolicy(allowedBlockTypes: readonly string[] | null, allowedMarkTypes: readonly string[] | null): void { this.update("modernSetContentPolicy", { allowedBlockTypes, allowedMarkTypes }); }
  setListPolicy(allowedListActions: readonly ModernListAction[] | null): void { this.update("modernSetListPolicy", { allowedListActions }); }
  endTypingGroup(): void { this.update("modernEndTypingGroup"); }
  holdRemoteChanges(): () => void {
    const hold = crypto.randomUUID(); this.update("modernHoldRemote", { hold }); let released = false;
    return () => { if (released || this.closed) return; released = true; this.update("modernReleaseRemote", { hold }); };
  }
  deferredChanges(): readonly ModernBatch[] { return this.call("modernDeferredChanges"); }
  restoreDeferredChanges(packets: readonly ModernBatch[]): void { this.update("modernRestoreDeferredChanges", { packets }); }
  retryDeferredChanges(): void { this.update("modernRetryDeferredChanges"); }
  setLocalSelection(selection: ModernLocalSelection | null): void { this.update("modernSetLocalSelection", { selection }); }
  localSelection(): ModernLocalSelection | null { return this.call("modernLocalSelection"); }
  exportHistorySelection(): ModernHistorySelectionArchive { return this.call("modernExportHistorySelection"); }
  restoreHistorySelection(archive: ModernHistorySelectionArchive): void { this.update("modernRestoreHistorySelection", { archive }); }
  close(): void { if (this.closed) return; this.call("destroy"); this.closed = true; this.listeners.clear(); }
}

export interface ModernCutoverArchive extends ModernScope {
  readonly version: 1; readonly originals: readonly string[];
  readonly source: { readonly document: { readonly format: "blockArray" | "documentObject"; readonly bytes: string } }
    | { readonly session: { readonly acceptedSnapshot: string; readonly reconciledSnapshot: string; readonly pendingRecovery?: string; readonly unacknowledged: readonly string[] } };
}
export interface ModernCutoverIdentity {
  readonly source: { readonly legacyPath: { readonly _0: { readonly blockID: string; readonly path: readonly string[] } } } | { readonly origin: { readonly _0: ModernNodeID } };
  readonly address: { readonly blockID: string; readonly path: readonly string[] }; readonly target: ModernNodeID;
}
export type ModernCutoverPreparation = { readonly archiveID: string; readonly status: "prepared" | "applied"; readonly byteCount: number; readonly verifiedBytes: number; readonly document: ModernDocument; readonly originMapping: readonly ModernCutoverIdentity[] }
  | { readonly archiveID: string; readonly status: "unavailable"; readonly reason: "incompatibleLegacyRepresentation" | "unreconciledLegacyInput" };
export type ModernCutoverProgress = { readonly archiveID: string; readonly byteCount: number } & ({ readonly status: "uploading"; readonly receivedBytes: number } | { readonly status: "prepared" | "applied"; readonly verifiedBytes: number });
/** Local preparation only. Hosts persist actual exported bytes and supply actual storage
 * readback; this helper does not activate a durable pointer or infer acknowledgments. */
export class SwiftModernCutover {
  constructor(private readonly transport: ModernTransport) {}
  private call<T>(command: string, args: Record<string, unknown>): T { return owned(this.transport.call<T>({ command, ...args })); }
  begin(byteCount: number): ModernCutoverProgress { return this.call("modernBeginCutoverArchive", { byteCount }); }
  append(archiveID: string, offset: number, bytes: string): ModernCutoverProgress { return this.call("modernAppendCutoverArchive", { archiveID, offset, bytes }); }
  prepare(archive: ModernCutoverArchive): ModernCutoverPreparation { return this.call("modernPrepareCutover", { archive }); }
  prepareUploaded(archiveID: string): ModernCutoverPreparation { return this.call("modernPrepareCutover", { archiveID }); }
  bytes(archiveID: string, offset: number, length: number): { readonly archiveID: string; readonly byteCount: number; readonly offset: number; readonly bytes: string } { return this.call("modernCutoverArchiveBytes", { archiveID, offset, length }); }
  verifyReadback(archiveID: string, offset: number, bytes: string): ModernCutoverProgress { return this.call("modernVerifyCutoverReadback", { archiveID, offset, bytes }); }
  remapPosition(archiveID: string, kind: "text", position: SwiftTextPosition): ModernPosition;
  remapPosition(archiveID: string, kind: "writing", position: SwiftWritingPosition): ModernPosition;
  remapPosition(archiveID: string, kind: "text" | "writing", position: SwiftTextPosition | SwiftWritingPosition): ModernPosition { return this.call("modernRemapCutoverPosition", { archiveID, kind, position }); }
  forget(archiveID: string): void { this.call("modernForgetCutoverArchive", { archiveID }); }
}
