import { open, readFile, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import type { ModernDocument, ModernObject, ModernBatch, ModernReceipt } from "../../src/swift-modern.ts";
import type { NativeBridge } from "./bridge.ts";

export interface ModernRelayRoomTemplate { readonly document: ModernDocument; readonly epoch: string }

async function persist(directory: string, file: string, snapshot: ModernObject): Promise<void> {
  const bytes = JSON.stringify(snapshot), temporary = `${file}.${randomUUID()}.tmp`;
  try {
    const output = await open(temporary, "wx", 0o600);
    try { await output.writeFile(bytes); await output.sync(); } finally { await output.close(); }
    await rename(temporary, file);
    const parent = await open(directory, "r");
    try { await parent.sync(); } finally { await parent.close(); }
    if (await readFile(file, "utf8") !== bytes) throw new Error("Modern relay persistence readback mismatch");
  } finally { await rm(temporary, { force: true }); }
}

/** The local reference service owns one directory. Every request restores a
 * detached Swift session, validates it, and publishes only after disk readback.
 * A failure after rename has an unknown ACK outcome; the next request reloads
 * the real file instead of relying on a stale in-memory room. */
export async function modernRoom(bridge: NativeBridge, directory: string, id: string, template: ModernRelayRoomTemplate,
  input?: { batch: ModernBatch; state: ModernReceipt }) {
  const file = join(directory, `${id}.json`), handle = `modern-relay-${randomUUID()}`;
  const call = (command: string, fields: Record<string, unknown> = {}) => bridge.call({ command, session: handle, ...fields });
  let existing: ModernObject | undefined;
  try { existing = JSON.parse(await readFile(file, "utf8")); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
  let opened = false;
  try {
    const snapshot = existing
      ? await call("restoreModern", { actorID: "relay", snapshot: existing })
      : await call("createModern", { actorID: "relay", documentID: id, epoch: template.epoch, collaborationVersion: 7,
        document: { ...template.document, documentID: id } });
    opened = true;
    if (snapshot.syncState.documentID !== id || snapshot.syncState.epoch !== template.epoch) throw new Error("Modern relay scope differs; use explicit archival cutover");
    if (input) {
      // Validate the caller's receipt before any durable state or presence changes.
      await call("modernChanges", { since: input.state });
      await call("modernReceive", { batch: input.batch });
    }
    const accepted = await call("modernSave") as ModernObject;
    const batch = input ? await call("modernChanges", { since: input.state }) as ModernBatch : undefined;
    const state = (await call("modernSnapshot")).syncState as ModernReceipt;
    if (input || !existing) await persist(directory, file, accepted);
    return { snapshot: accepted, ...(input ? { batch: batch!, state } : {}) };
  } finally { if (opened) await call("destroy"); }
}
