import { WASI, File, OpenFile, ConsoleStdout } from "@bjorn3/browser_wasi_shim";
import type { Block, Mark, InlineNode } from "./schema.js";

export interface SwiftElementID { change: { counter: number; actor: string }; index: number }
/** Origin identities are immutable. Hosts should obtain them from session.node(). */
export type SwiftNodeID = { baseline: { blockID: string; path: string[] } } | { inserted: { creation: SwiftElementID; path: string[] } };
export interface SwiftNodeAddress { blockID: string; path: string[] }
export type SwiftNodeCollection = { owner?: null; field: "blocks" } | { owner: SwiftNodeID; field: "children" | "items" | "rows" | "cells" };
export interface TextAddress { blockID: string; path: string[]; identity?: SwiftNodeID | null }
export interface SwiftTextPosition {
  documentID: string;
  address: TextAddress;
  anchor?: { change: { counter: number; actor: string }; index: number } | null;
  affinity: "before" | "after";
  intraAtomOffset?: number | null;
}
export interface SwiftSnapshot { blocks: Block[]; canUndo: boolean; canRedo: boolean }
/** Opaque, versioned payloads: hosts transport them without interpreting merge operations. */
export type SwiftChangeBatch = { version: number; documentID: string; baseline: unknown; changes: unknown[] };
/** Persist separately from save(); its changes have not been acknowledged or applied. */
export interface SwiftMergeRecovery { reason: "identityConflict" | "schemaConstraint"; batch: SwiftChangeBatch }
export type SwiftMergeRepair =
  | { move: { identity: SwiftNodeID; collection: SwiftNodeCollection } }
  | { wrap: { identity: SwiftNodeID; container: Block; field: "children" | "items" | "rows" } }
  | { text: { identity: SwiftNodeID; field: string; text: string } };
export class SwiftMergeRecoveryError extends Error {
  constructor(readonly recovery: SwiftMergeRecovery) {
    super("Merge recovery required"); this.name = "SwiftMergeRecoveryError";
  }
}
export type SwiftSyncState = { received: unknown[]; documentID?: string; version?: number };
export type SwiftPresence = { actor: string; revision: number; address?: TextAddress; anchor?: unknown; focus?: unknown };

export interface SwiftWritingField { node: SwiftNodeID; name: string }
export interface SwiftWritingAtomKey { origin: SwiftWritingField; element: SwiftElementID }
export interface SwiftWritingPosition {
  documentID: string; epoch: string; field: SwiftWritingField;
  anchor?: SwiftWritingAtomKey | null; affinity: "before" | "after"; intraAtomOffset?: number | null;
}
export interface SwiftWritingTextRange { start: SwiftWritingPosition; end: SwiftWritingPosition }
export interface SwiftWritingSelection { nodes: SwiftNodeID[]; text: SwiftWritingTextRange[] }
export interface SwiftWritingCopy { nodes: unknown[]; text: InlineNode[][] }
export interface SwiftResolvedWritingPosition { address: TextAddress; offset: number }
export interface SwiftWritingBatch extends SwiftChangeBatch { version: 3; epoch: string }
export interface SwiftWritingReceipt { version: 3; documentID: string; epoch: string; received: unknown[] }
export interface SwiftWritingRecovery { reason: "identityConflict" | "schemaConstraint"; batch: SwiftWritingBatch }
export class SwiftWritingRecoveryError extends Error {
  constructor(readonly recovery: SwiftWritingRecovery) { super("Writing recovery required"); this.name = "SwiftWritingRecoveryError"; }
}
/** Snapshot strings are base64-encoded UTF-8 JSON, preserving archived local history. */
export interface SwiftWritingCutoverArchive {
  acceptedSnapshot: string; pendingRecovery?: SwiftMergeRecovery | null; unacknowledged: SwiftChangeBatch[];
  reconciledSnapshot: string; epoch: string;
}

type Exports = WebAssembly.Exports & {
  memory: WebAssembly.Memory;
  _start: () => void;
  block_editor_alloc: (length: number) => number;
  block_editor_free: (pointer: number) => void;
  block_editor_call: (pointer: number, length: number) => number;
};

export class SwiftEditorRuntime {
  private constructor(private readonly exports: Exports) {}
  /** No automatic network access: the host supplies the module bytes or a compiled module. */
  static async initialize(source: BufferSource | WebAssembly.Module): Promise<SwiftEditorRuntime> {
    const module = source instanceof WebAssembly.Module ? source : await WebAssembly.compile(source);
    const wasi = new WASI([], [], [new OpenFile(new File([])), ConsoleStdout.lineBuffered(() => {}), ConsoleStdout.lineBuffered(() => {})], { debug: false });
    const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi.wasiImport });
    const exports = instance.exports as Exports;
    for (const name of ["block_editor_alloc", "block_editor_free", "block_editor_call", "_start"]) {
      if (typeof exports[name] !== "function") throw new Error(`Missing Swift WASM export: ${name}`);
    }
    if (!(exports.memory instanceof WebAssembly.Memory)) throw new Error("Missing Swift WASM memory");
    const status = wasi.start({ exports });
    if (status !== 0) throw new Error(`Swift WASM initialization failed (${status})`);
    return new SwiftEditorRuntime(exports);
  }
  call<T>(request: Record<string, unknown>): T {
    const bytes = new TextEncoder().encode(JSON.stringify(request));
    const input = this.exports.block_editor_alloc(bytes.length + 1);
    if (!input) throw new Error("Swift request exceeds the runtime limit");
    let output = 0;
    try {
      new Uint8Array(this.exports.memory.buffer, input, bytes.length).set(bytes);
      output = this.exports.block_editor_call(input, bytes.length);
      if (!output) throw new Error("Swift engine returned no response");
      const memory = new Uint8Array(this.exports.memory.buffer);
      const end = memory.indexOf(0, output);
      if (end === -1) throw new Error("Invalid Swift response buffer");
      const response = JSON.parse(new TextDecoder().decode(memory.subarray(output, end))) as { ok: boolean; value?: T; error?: string; recovery?: SwiftMergeRecovery | SwiftWritingRecovery };
      if (!response.ok) {
        if (response.error === "writingRecoveryRequired" && response.recovery) throw new SwiftWritingRecoveryError(response.recovery as SwiftWritingRecovery);
        if (response.error === "mergeRecoveryRequired" && response.recovery) throw new SwiftMergeRecoveryError(response.recovery);
        throw new Error(response.error ?? "Swift editor operation failed");
      }
      return response.value as T;
    } finally {
      if (output) this.exports.block_editor_free(output);
      this.exports.block_editor_free(input);
    }
  }
  create(options: { documentID: string; actorID: string; blocks: Block[]; collaborationVersion?: 1 | 2 }): SwiftEditorSession {
    const handle = crypto.randomUUID();
    return new SwiftEditorSession(this, handle, this.call({ command: "create", session: handle, ...options }));
  }
  restore(snapshot: SwiftChangeBatch, actorID: string): SwiftEditorSession {
    const handle = crypto.randomUUID();
    return new SwiftEditorSession(this, handle, this.call({ command: "restore", session: handle, snapshot, actorID }));
  }
  /** Stop old writers and archive their snapshot first. Cutover starts fresh undo history. */
  cutoverToV2(snapshot: SwiftChangeBatch, options: { documentID: string; actorID: string }): SwiftEditorSession {
    const handle = crypto.randomUUID();
    return new SwiftEditorSession(this, handle, this.call({ command: "cutoverToV2", session: handle, snapshot, ...options }));
  }
  createWriting(options: { documentID: string; actorID: string; epoch: string; blocks: Block[] }): SwiftWritingSession {
    const handle = crypto.randomUUID();
    return new SwiftWritingSession(this, handle, this.call({ command: "create", session: handle, collaborationVersion: 3, ...options }));
  }
  restoreWriting(snapshot: SwiftWritingBatch, actorID: string): SwiftWritingSession {
    const handle = crypto.randomUUID();
    return new SwiftWritingSession(this, handle, this.call({ command: "restore", session: handle, snapshot, actorID }));
  }
  cutoverToV3(archive: SwiftWritingCutoverArchive, options: { actorID: string; oldWritersStopped: true; archivePersisted: true; resetUndoAcknowledged: true }): SwiftWritingSession {
    const handle = crypto.randomUUID();
    return new SwiftWritingSession(this, handle, this.call({ command: "cutoverToV3", session: handle, archive, ...options }));
  }
}

/** Explicit v3 facade. Commit composition before structural commands and hold
 * remote delivery while the platform owns an uncommitted input buffer. */
export class SwiftWritingSession {
  private listeners = new Set<() => void>();
  private beforeReceive = new Set<() => void | (() => void)>();
  private closed = false;
  private holds = 0;
  private deferred: string[] = [];
  private drainingCount = 0;
  private drainingBytes = 0;
  private draining = false;
  constructor(private runtime: SwiftEditorRuntime, private handle: string, private snapshot: SwiftSnapshot) {}
  getSnapshot = (): SwiftSnapshot => this.snapshot;
  subscribe = (listener: () => void): (() => void) => { this.listeners.add(listener); return () => this.listeners.delete(listener); };
  subscribeBeforeReceive = (listener: () => void | (() => void)): (() => void) => { this.beforeReceive.add(listener); return () => this.beforeReceive.delete(listener); };
  private call<T>(command: string, args: Record<string, unknown> = {}): T {
    if (this.closed) throw new Error("Writing session is closed");
    return this.runtime.call({ command, session: this.handle, ...args });
  }
  private publish(snapshot: SwiftSnapshot): void { this.snapshot = snapshot; for (const listener of this.listeners) listener(); }
  private command(command: string, args: Record<string, unknown>): SwiftWritingPosition {
    const result = this.call<{ snapshot: SwiftSnapshot; position: SwiftWritingPosition }>(command, args);
    this.publish(result.snapshot); return result.position;
  }
  node(address: SwiftNodeAddress): SwiftNodeID { return this.call("node", { address }); }
  nodeAddress(identity: SwiftNodeID): SwiftNodeAddress { return this.call("nodeAddress", { identity }); }
  textAddress(identity: SwiftNodeID, field = "content"): TextAddress { return this.call("textAddress", { identity, field }); }
  position(address: TextAddress, offset: number, affinity: SwiftWritingPosition["affinity"] = "before"): SwiftWritingPosition { return this.call("position", { address, offset, affinity }); }
  resolvePosition(position: SwiftWritingPosition): SwiftResolvedWritingPosition { return this.call("resolvePosition", { position }); }
  setComposing(active: boolean): void { this.call("composition", { active }); }
  replaceText(address: TextAddress, start: number, end: number, text: string, marks?: Mark[]): SwiftWritingPosition { return this.command("replaceText", { address, start, end, text, marks }); }
  softBreak(address: TextAddress, start: number, end: number): SwiftWritingPosition { return this.command("softBreak", { address, start, end }); }
  splitParagraph(address: TextAddress, start: number, end: number, newBlockID: string): SwiftWritingPosition { return this.command("splitParagraph", { address, start, end, newBlockID }); }
  selectedText(address: TextAddress, start: number, end: number): SwiftWritingTextRange { return this.call("selectedText", { address, start, end }); }
  selection(anchor: SwiftWritingPosition, focus: SwiftWritingPosition): SwiftWritingSelection { return this.call("writingSelection", { anchor, focus }); }
  copySelection(selection: SwiftWritingSelection): SwiftWritingCopy { return this.call("copySelection", { selection }); }
  deleteSelection(selection: SwiftWritingSelection): SwiftWritingSelection {
    const result = this.call<{ snapshot: SwiftSnapshot; selection: SwiftWritingSelection }>("deleteSelection", { selection });
    this.publish(result.snapshot); return result.selection;
  }
  moveSelection(selection: SwiftWritingSelection, collection: SwiftNodeCollection, after?: SwiftNodeID): SwiftWritingSelection { return this.batch("moveSelection", selection, collection, after); }
  duplicateSelection(selection: SwiftWritingSelection, collection: SwiftNodeCollection, after?: SwiftNodeID): SwiftWritingSelection { return this.batch("duplicateSelection", selection, collection, after); }
  private batch(command: string, selection: SwiftWritingSelection, collection: SwiftNodeCollection, after?: SwiftNodeID): SwiftWritingSelection {
    const result = this.call<{ snapshot: SwiftSnapshot; selection: SwiftWritingSelection }>(command, { selection, collection, after });
    this.publish(result.snapshot); return result.selection;
  }
  mergeParagraphs(left: SwiftNodeID, right: SwiftNodeID): SwiftWritingPosition { return this.command("mergeParagraphs", { left, right }); }
  format(address: TextAddress, start: number, end: number, markType: Mark["type"], mark: Mark | null): void { this.publish(this.call("format", { address, start, end, markType, mark })); }
  undo(): void { this.publish(this.call("undo")); }
  redo(): void { this.publish(this.call("redo")); }
  save(): SwiftWritingBatch { return this.call("save"); }
  syncState(): SwiftWritingReceipt { return this.call("syncState"); }
  changes(since?: SwiftWritingReceipt): SwiftWritingBatch { return this.call("changes", { since }); }
  mergeRecovery(): SwiftWritingRecovery | null { return this.call("mergeRecovery"); }
  restoreRecovery(recovery: SwiftWritingRecovery): void { this.publish(this.call("restoreRecovery", { recovery })); }
  repairUndo(target: SwiftElementID["change"]): void {
    if (this.holds) throw new Error("Commit composition before repairing writing");
    this.publish(this.call("repairWritingUndo", { target }));
  }
  exportDeferredChanges(): SwiftWritingBatch[] { return this.deferred.map(value => JSON.parse(value) as SwiftWritingBatch); }
  deferRemoteChanges(): () => void {
    if (this.closed) throw new Error("Writing session is closed");
    this.holds++; let released = false;
    return () => { if (released || this.closed) return; released = true; if (--this.holds === 0) this.retryDeferredChanges(); };
  }
  retryDeferredChanges(): void {
    if (this.holds || this.draining || this.closed) throw new Error("Remote delivery is held");
    const pending = this.deferred; this.deferred = [];
    this.draining = true; this.drainingCount = pending.length;
    this.drainingBytes = pending.reduce((sum, packet) => sum + new TextEncoder().encode(packet).length, 0);
    const failed: string[] = []; let failure: unknown;
    try {
      for (const packet of pending) {
        let retained = false;
        try { this.receive(JSON.parse(packet)); }
        catch (error) { if (!(error instanceof SwiftWritingRecoveryError)) { failed.push(packet); retained = true; } failure ??= error; }
        if (!retained) { this.drainingCount--; this.drainingBytes -= new TextEncoder().encode(packet).length; }
      }
      this.deferred.unshift(...failed);
    } finally { this.draining = false; this.drainingCount = 0; this.drainingBytes = 0; }
    if (failure && (failed.length || this.mergeRecovery())) throw failure;
  }
  receive(batch: SwiftWritingBatch): void {
    if (this.closed) throw new Error("Writing session is closed");
    if (this.holds) {
      const packet = JSON.stringify(batch), bytes = new TextEncoder().encode(packet).length;
      const retained = this.deferred.reduce((sum, value) => sum + new TextEncoder().encode(value).length, 0);
      if (this.deferred.length + this.drainingCount >= 64 || retained + this.drainingBytes + bytes > 64_000_000) throw new Error("Pending writing changes exceed the composition buffer");
      this.deferred.push(packet); return;
    }
    const cleanup = [...this.beforeReceive].map(listener => listener());
    let snapshot: SwiftSnapshot;
    try { snapshot = this.call("receive", { batch }); }
    catch (error) { for (const undo of cleanup) { try { undo?.(); } catch { /* Preserve the engine failure. */ } } throw error; }
    this.publish(snapshot);
  }
  close(options: { pendingStateRetained?: boolean } = {}): void {
    if (!this.closed) {
      if (this.draining || (this.deferred.length && !options.pendingStateRetained)) throw new Error("Retain deferred changes before closing");
      this.call("close"); this.closed = true; this.listeners.clear(); this.beforeReceive.clear();
    }
  }
}

export class SwiftEditorSession {
  private listeners = new Set<() => void>();
  private recoveryListeners = new Set<() => void>();
  private recovery: SwiftMergeRecovery | null = null;
  private beforeReceive = new Set<() => void | (() => void)>();
  private remoteHolds = 0;
  private deferred: string[] = [];
  private deferredBytes = 0;
  private closed = false;
  constructor(private runtime: SwiftEditorRuntime, private handle: string, private snapshot: SwiftSnapshot) {}
  getSnapshot = (): SwiftSnapshot => this.snapshot;
  subscribe = (listener: () => void): (() => void) => { this.listeners.add(listener); return () => this.listeners.delete(listener); };
  /** Recovery can change on a rejected receive without a document change. */
  getRecoverySnapshot = (): SwiftMergeRecovery | null => this.recovery;
  subscribeRecovery = (listener: () => void): (() => void) => { this.recoveryListeners.add(listener); return () => this.recoveryListeners.delete(listener); };
  /** A pre-receive observer can return cleanup to discard preparation if validation fails. */
  subscribeBeforeReceive = (listener: () => void | (() => void)): (() => void) => { this.beforeReceive.add(listener); return () => this.beforeReceive.delete(listener); };
  /** An input adapter commits its composition before releasing queued remote edits.
   * Receipt state excludes queued batches, so transports keep them pending. */
  deferRemoteChanges(): () => void {
    if (this.closed) throw new Error("Editor session is closed");
    this.remoteHolds++;
    let released = false;
    return () => {
      if (released || this.closed) return;
      released = true;
      if (--this.remoteHolds) return;
      const batches = this.deferred; this.deferred = []; this.deferredBytes = 0;
      let failure: unknown;
      for (const batch of batches) {
        try { this.receive(JSON.parse(batch)); } catch (error) { failure ??= error; }
      }
      if (failure) throw failure;
    };
  }
  private call<T>(command: string, args: Record<string, unknown> = {}): T {
    if (this.closed) throw new Error("Editor session is closed");
    try {
      const value = this.runtime.call<T>({ command, session: this.handle, ...args });
      if (["receive", "repairMerge", "undo", "redo"].includes(command)) {
        this.setRecovery(this.runtime.call({ command: "mergeRecovery", session: this.handle }));
      }
      return value;
    } catch (error) {
      if (error instanceof SwiftMergeRecoveryError) this.setRecovery(error.recovery);
      throw error;
    }
  }
  private setRecovery(value: SwiftMergeRecovery | null) {
    if (JSON.stringify(value) === JSON.stringify(this.recovery)) return;
    this.recovery = value;
    for (const listener of this.recoveryListeners) listener();
  }
  private edit(command: string, args: Record<string, unknown> = {}): void {
    this.snapshot = this.call(command, args);
    for (const listener of this.listeners) listener();
  }
  setText(address: TextAddress, text: string): void { this.edit("setText", { address, text }); }
  mergeRecovery(): SwiftMergeRecovery | null { return this.call("mergeRecovery"); }
  /** Re-submit a retained recovery.batch with receive() after restoring accepted history. */
  repairMerge(repairs: SwiftMergeRepair[]): void {
    if (this.remoteHolds) throw new Error("Commit composition before repairing a merge");
    const rollback = [...this.beforeReceive].map(listener => listener());
    try { this.edit("repairMerge", { repairs }); }
    catch (error) { for (const cleanup of rollback) { try { cleanup?.(); } catch { /* Keep the engine error. */ } } throw error; }
  }
  node(address: SwiftNodeAddress): SwiftNodeID { return this.call("node", { address }); }
  nodeAddress(identity: SwiftNodeID): SwiftNodeAddress { return this.call("nodeAddress", { identity }); }
  nodes(collection: SwiftNodeCollection): SwiftNodeID[] { return this.call("nodes", { collection }); }
  textAddress(identity: SwiftNodeID, field = "content"): TextAddress { return this.call("textAddress", { identity, field }); }
  insertNode(value: unknown, collection: SwiftNodeCollection, after?: SwiftNodeID): SwiftNodeID {
    const result = this.call<{ identity: SwiftNodeID; snapshot: SwiftSnapshot }>("insertNode", { value, collection, after });
    this.snapshot = result.snapshot;
    for (const listener of this.listeners) listener();
    return result.identity;
  }
  moveNode(identity: SwiftNodeID, collection: SwiftNodeCollection, after?: SwiftNodeID): void { this.edit("moveNode", { identity, collection, after }); }
  deleteNode(identity: SwiftNodeID): void { this.edit("deleteNode", { identity }); }
  indent(identity: SwiftNodeID): void { this.edit("indent", { identity }); }
  outdent(identity: SwiftNodeID): void { this.edit("outdent", { identity }); }
  setNodeField(identity: SwiftNodeID, path: string[], value: unknown): void { this.edit("setNodeField", { identity, path, value }); }
  position(address: TextAddress, offset: number, affinity: SwiftTextPosition["affinity"] = "before"): SwiftTextPosition {
    return this.call("position", { address, offset, affinity });
  }
  resolvePosition(position: SwiftTextPosition): number { return this.call("resolvePosition", { position }); }
  setInline(address: TextAddress, nodes: InlineNode[]): void { this.edit("setInline", { address, nodes }); }
  replaceText(address: TextAddress, start: number, end: number, text: string, marks?: Mark[]): void {
    this.edit("replaceText", { address, start, end, text, marks });
  }
  format(address: TextAddress, start: number, end: number, markType: Mark["type"], mark: Mark | null): void {
    this.edit("format", { address, start, end, markType, mark });
  }
  insert(block: Block, after?: string): void { this.edit("insert", { block, after }); }
  move(blockID: string, after?: string): void { this.edit("move", { blockID, after }); }
  delete(blockID: string): void { this.edit("delete", { blockID }); }
  setField(blockID: string, path: string[], value: unknown): void { this.edit("setField", { blockID, path, value }); }
  undo(): void { this.edit("undo"); }
  redo(): void { this.edit("redo"); }
  save(): SwiftChangeBatch { return this.call("save"); }
  syncState(): SwiftSyncState { return this.call("syncState"); }
  changes(since?: SwiftSyncState): SwiftChangeBatch { return this.call("changes", { since }); }
  receive(batch: SwiftChangeBatch): void {
    if (this.closed) throw new Error("Editor session is closed");
    if (this.remoteHolds) {
      const payload = JSON.stringify(batch), bytes = new TextEncoder().encode(payload).length;
      if (this.deferred.length >= 64 || this.deferredBytes + bytes > 64_000_000) throw new Error("Pending remote changes exceed the composition buffer; retry after composition ends");
      this.deferred.push(payload); this.deferredBytes += bytes;
      return;
    }
    const rollback = [...this.beforeReceive].map(listener => listener());
    let next: SwiftSnapshot;
    try { next = this.call("receive", { batch }); }
    catch (error) {
      for (const cleanup of rollback) { try { cleanup?.(); } catch { /* Keep the engine error. */ } }
      throw error;
    }
    this.snapshot = next;
    for (const listener of this.listeners) listener();
  }
  receivePresence(presence: SwiftPresence): Record<string, SwiftPresence> { return this.call("presence", { presence }); }
  removePresence(actorID: string): Record<string, SwiftPresence> { return this.call("removePresence", { actorID }); }
  setAllowedBlockTypes(types: string[] | null): void { this.edit("allowedBlockTypes", { types }); }
  markdown(): string { return this.call("markdown"); }
  close(): void { if (!this.closed) { this.call("close"); this.closed = true; this.listeners.clear(); this.recoveryListeners.clear(); this.beforeReceive.clear(); this.deferred = []; this.deferredBytes = 0; } }
}
