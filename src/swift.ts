import { WASI, File, OpenFile, ConsoleStdout } from "@bjorn3/browser_wasi_shim";
import type { Block, Mark, InlineNode } from "./schema.js";

export interface TextAddress { blockID: string; path: string[] }
export interface SwiftSnapshot { blocks: Block[]; canUndo: boolean; canRedo: boolean }
/** Opaque, versioned payloads: hosts transport them without interpreting merge operations. */
export type SwiftChangeBatch = { version: number; documentID: string; baseline: unknown; changes: unknown[] };
export type SwiftSyncState = { received: unknown[] };
export type SwiftPresence = { actor: string; revision: number; address?: TextAddress; anchor?: unknown; focus?: unknown };

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
      const response = JSON.parse(new TextDecoder().decode(memory.subarray(output, end))) as { ok: boolean; value?: T; error?: string };
      if (!response.ok) throw new Error(response.error ?? "Swift editor operation failed");
      return response.value as T;
    } finally {
      if (output) this.exports.block_editor_free(output);
      this.exports.block_editor_free(input);
    }
  }
  create(options: { documentID: string; actorID: string; blocks: Block[] }): SwiftEditorSession {
    const handle = crypto.randomUUID();
    return new SwiftEditorSession(this, handle, this.call({ command: "create", session: handle, ...options }));
  }
  restore(snapshot: SwiftChangeBatch, actorID: string): SwiftEditorSession {
    const handle = crypto.randomUUID();
    return new SwiftEditorSession(this, handle, this.call({ command: "restore", session: handle, snapshot, actorID }));
  }
}

export class SwiftEditorSession {
  private listeners = new Set<() => void>();
  private closed = false;
  constructor(private runtime: SwiftEditorRuntime, private handle: string, private snapshot: SwiftSnapshot) {}
  getSnapshot = (): SwiftSnapshot => this.snapshot;
  subscribe = (listener: () => void): (() => void) => { this.listeners.add(listener); return () => this.listeners.delete(listener); };
  private call<T>(command: string, args: Record<string, unknown> = {}): T {
    if (this.closed) throw new Error("Editor session is closed");
    return this.runtime.call({ command, session: this.handle, ...args });
  }
  private edit(command: string, args: Record<string, unknown> = {}): void {
    this.snapshot = this.call(command, args);
    for (const listener of this.listeners) listener();
  }
  setText(address: TextAddress, text: string): void { this.edit("setText", { address, text }); }
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
  receive(batch: SwiftChangeBatch): void { this.edit("receive", { batch }); }
  receivePresence(presence: SwiftPresence): Record<string, SwiftPresence> { return this.call("presence", { presence }); }
  removePresence(actorID: string): Record<string, SwiftPresence> { return this.call("removePresence", { actorID }); }
  setAllowedBlockTypes(types: string[] | null): void { this.edit("allowedBlockTypes", { types }); }
  markdown(): string { return this.call("markdown"); }
  close(): void { if (!this.closed) { this.call("close"); this.closed = true; this.listeners.clear(); } }
}
