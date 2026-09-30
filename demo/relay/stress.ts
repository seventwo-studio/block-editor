import { NativeBridge } from "./bridge.ts";
import { plainText } from "../../src/model.ts";
import type { Block, InlineNode } from "../../src/schema.ts";

function textBoundaries(nodes: readonly InlineNode[]) {
  const offsets = [0];
  for (const node of nodes) {
    const parts = node.type === "text" ? Array.from(node.text) : [plainText([node])];
    for (const part of parts) offsets.push(offsets[offsets.length - 1] + part.length);
  }
  return [...new Set(offsets)];
}

export async function stressRelay(options: { url: string; token: string; executable: string; replicas?: number; rounds?: number; seed?: number; room?: string }) {
  const replicas = options.replicas ?? 4, rounds = options.rounds ?? 30;
  if (!Number.isInteger(replicas) || !Number.isInteger(rounds) || replicas < 2 || replicas > 32 || rounds < 1 || rounds > 500) throw new Error("Use 2–32 replicas and 1–500 rounds");
  let seed = options.seed ?? 42;
  if (!Number.isInteger(seed) || seed < 0 || seed > 0xffffffff) throw new Error("Use an unsigned 32-bit integer seed");
  const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 2 ** 32; };
  const endpoint = `${options.url}/rooms/${options.room ?? `stress-${Date.now()}`}`;
  const headers = { "x-local-token": options.token, "content-type": "application/json" };
  const initial = await fetch(endpoint, { headers });
  if (!initial.ok) throw new Error(await initial.text());
  const snapshot = await initial.json();
  const clients = Array.from({ length: replicas }, () => new NativeBridge(options.executable));
  const acknowledgements: Array<{ received: unknown[] }> = clients.map(() => ({ received: [] }));
  const operations = { insert: 0, replace: 0, delete: 0, format: 0, unformat: 0, undo: 0, redo: 0, blockInsert: 0, blockMove: 0, blockDelete: 0 };
  let exchanges = 0, partialExchanges = 0, restarts = 0;
  let context = "initial restore";
  const start = performance.now();
  try {
    for (let index = 0; index < replicas; index++)
      await clients[index].call({ command: "restore", session: "s", actorID: `actor-${index}`, snapshot });
    async function sync(index: number, complete = false) {
      const client = clients[index];
      const batch = await client.call({ command: "changes", session: "s", since: acknowledgements[index] });
      // Send newer operations before their predecessors, across separate HTTP
      // exchanges. Receipt gaps must remain available to subsequent delta sync.
      const reversed = [...batch.changes].reverse();
      const selected = complete ? reversed : reversed.slice(0, Math.max(1, Math.ceil(reversed.length / 2)));
      if (selected.length < reversed.length) partialExchanges++;
      batch.changes = selected.flatMap(change => [change, change]);
      const state = await client.call({ command: "syncState", session: "s" });
      const response = await fetch(endpoint, { method: "POST", headers, body: JSON.stringify({
        actorID: `actor-${index}`, batch, state,
        presence: { actor: `actor-${index}`, revision: ++exchanges, address: { blockID: "p", path: ["content"] } },
      }) });
      if (!response.ok) throw new Error(await response.text());
      const reply = await response.json();
      await client.call({ command: "receive", session: "s", batch: reply.batch });
      acknowledgements[index] = reply.state;
    }
    for (let round = 0; round < rounds; round++) {
      for (let index = 0; index < replicas; index++) {
        context = `round ${round}, actor ${index}`;
        const client = clients[index];
        const doc: { blocks: Block[] } = await client.call({ command: "document", session: "s" });
        const block = doc.blocks.find(b => b.id === "p");
        if (block?.type !== "paragraph") throw new Error("Stress room must contain the shared paragraph");
        const text = plainText(block.content), offsets = textBoundaries(block.content);
        const first = Math.floor(random() * offsets.length), second = Math.floor(random() * offsets.length);
        const start = offsets[Math.min(first, second)], end = offsets[Math.max(first, second)];
        const mode = (round + index) % 6, address = { blockID: "p", path: ["content"] };
        if (mode === 3 || mode === 4) {
          const markType = ["bold", "italic", "strikethrough"][Math.floor(random() * 3)];
          await client.call({ command: "format", session: "s", address, start, end, markType, mark: mode === 3 ? { type: markType } : null });
          operations[mode === 3 ? "format" : "unformat"]++;
        } else {
          const inserted = mode === 2 ? "" : ["😀", "e\u0301", "世界", "👩🏽‍💻", "אב", "\n"][Math.floor(random() * 6)];
          const from = mode === 0 || mode === 5 ? end : start;
          const result = await client.call({ command: "replaceText", session: "s", address, start: from, end, text: inserted });
          const updated = result.blocks.find((b: Block) => b.id === "p");
          if (plainText(updated.content) !== text.slice(0, from) + inserted + text.slice(end)) throw new Error("Local edit lost or changed unrelated text");
          operations[mode === 2 ? "delete" : mode === 1 ? "replace" : "insert"]++;
        }
        if (round % 5 === 0) {
          await client.call({ command: "insert", session: "s", after: "p", block: { id: `b-${index}-${round}`, type: "paragraph", content: [{ type: "text", text: "Structural edit", marks: [] }] } });
          operations.blockInsert++;
        }
        if (round % 5 === 1) {
          const id = `b-${index}-${round - 1}`;
          await client.call({ command: "move", session: "s", blockID: id });
          await client.call({ command: "delete", session: "s", blockID: id });
          operations.blockMove++; operations.blockDelete++;
        }
        if (round % 7 === 3) {
          await client.call({ command: "undo", session: "s" }); await client.call({ command: "redo", session: "s" });
          operations.undo++; operations.redo++;
        }
        if (round % 6 === 4) {
          const saved = await client.call({ command: "save", session: "s" });
          const before = await client.call({ command: "document", session: "s" });
          client.close(); clients[index] = new NativeBridge(options.executable);
          const after = await clients[index].call({ command: "restore", session: "s", actorID: `actor-${index}`, snapshot: saved });
          if (JSON.stringify(before) !== JSON.stringify(after)) throw new Error("Process restart changed document or local history");
          restarts++;
        }
        // One replica stays offline for the first half; others have seeded random outages.
        if (!(index === 0 && round < rounds / 2) && random() > 0.45) await sync(index);
      }
    }
    // First flush every replica; second exchange distributes the final union to all.
    context = "final recovery";
    for (let pass = 0; pass < 2; pass++) for (let index = 0; index < replicas; index++) await sync(index, true);
    const documents = await Promise.all(clients.map(client => client.call({ command: "document", session: "s" })));
    const canonical = JSON.stringify(documents[0].blocks);
    if (!documents.every(doc => JSON.stringify(doc.blocks) === canonical)) throw new Error("Replicas diverged after rejoining");
    const final = await (await fetch(endpoint, { headers })).json();
    const observer = new NativeBridge(options.executable);
    try {
      const doc = await observer.call({ command: "restore", session: "s", actorID: "observer", snapshot: final });
      if (JSON.stringify(doc.blocks) !== canonical) throw new Error("Persisted server snapshot differs from clients");
      const serverState = await observer.call({ command: "syncState", session: "s" });
      for (const client of clients) {
        const state = await client.call({ command: "syncState", session: "s" });
        const pending = await client.call({ command: "changes", session: "s", since: serverState });
        const missing = await observer.call({ command: "changes", session: "s", since: state });
        if (pending.changes.length || missing.changes.length) throw new Error("Recovery left unacknowledged or missing changes");
      }
    } finally { observer.close(); }
    if ("presence" in final) throw new Error("Presence leaked into persisted content");
    return { replicas, rounds, exchanges, partialExchanges, restarts, attemptedOperations: operations, seed: options.seed ?? 42, milliseconds: Math.round(performance.now() - start), documentBytes: new TextEncoder().encode(canonical).length, converged: true, acknowledged: true };
  } catch (error) {
    throw new Error(`Stress seed ${options.seed ?? 42}, ${context}: ${String(error)}`, { cause: error });
  } finally { clients.forEach(client => client.close()); }
}

if (import.meta.main) console.log(JSON.stringify(await stressRelay({
  url: process.env.DEMO_URL ?? "http://127.0.0.1:4319", token: process.env.DEMO_TOKEN ?? "",
  executable: process.env.BLOCK_EDITOR_BRIDGE ?? "./.build/debug/editor-bridge",
  replicas: Number(process.env.STRESS_REPLICAS ?? 4), rounds: Number(process.env.STRESS_ROUNDS ?? 30), seed: Number(process.env.STRESS_SEED ?? 42),
}), null, 2));
