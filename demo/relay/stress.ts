import { NativeBridge } from "./bridge.ts";

export async function stressRelay(options: { url: string; token: string; executable: string; replicas?: number; rounds?: number; seed?: number; room?: string }) {
  const replicas = options.replicas ?? 4, rounds = options.rounds ?? 30;
  if (replicas < 2 || replicas > 32 || rounds < 1 || rounds > 500) throw new Error("Use 2–32 replicas and 1–500 rounds");
  let seed = options.seed ?? 42;
  const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 2 ** 32; };
  const endpoint = `${options.url}/rooms/${options.room ?? `stress-${Date.now()}`}`;
  const headers = { "x-local-token": options.token, "content-type": "application/json" };
  const initial = await fetch(endpoint, { headers });
  if (!initial.ok) throw new Error(await initial.text());
  const snapshot = await initial.json();
  const clients = Array.from({ length: replicas }, () => new NativeBridge(options.executable));
  let exchanges = 0;
  const start = performance.now();
  try {
    for (let index = 0; index < replicas; index++)
      await clients[index].call({ command: "restore", session: "s", actorID: `actor-${index}`, snapshot });
    async function sync(index: number) {
      const client = clients[index];
      const batch = await client.call({ command: "changes", session: "s" });
      // Stress duplicate operations and reverse causal delivery inside each batch.
      batch.changes = [...batch.changes].reverse().flatMap(change => [change, change]);
      const state = await client.call({ command: "syncState", session: "s" });
      const response = await fetch(endpoint, { method: "POST", headers, body: JSON.stringify({
        actorID: `actor-${index}`, batch, state,
        presence: { actor: `actor-${index}`, revision: ++exchanges, address: { blockID: "p", path: ["content"] } },
      }) });
      if (!response.ok) throw new Error(await response.text());
      const reply = await response.json();
      await client.call({ command: "receive", session: "s", batch: reply.batch });
    }
    for (let round = 0; round < rounds; round++) {
      for (let index = 0; index < replicas; index++) {
        const client = clients[index];
        const doc: { blocks: Array<{ id: string; content?: Array<{ text?: string }> }> } = await client.call({ command: "document", session: "s" });
        const block = doc.blocks.find(b => b.id === "p");
        if (!block?.content) throw new Error("Stress room must contain the shared paragraph");
        const text = block.content.map(n => n.text ?? "").join("");
        const offset = text.length;
        await client.call({ command: "replaceText", session: "s", address: { blockID: "p", path: ["content"] }, start: offset, end: offset, text: `[${index}:${round}:😀]` });
        if (round % 4 === 0) await client.call({ command: "format", session: "s", address: { blockID: "p", path: ["content"] }, start: 0, end: 1, markType: "bold", mark: { type: "bold" } });
        if (round % 5 === 0) await client.call({ command: "insert", session: "s", after: "p", block: { id: `b-${index}-${round}`, type: "paragraph", content: [{ type: "text", text: "Structural edit", marks: [] }] } });
        if (round % 5 === 1) {
          const id = `b-${index}-${round - 1}`;
          await client.call({ command: "move", session: "s", blockID: id });
          await client.call({ command: "delete", session: "s", blockID: id });
        }
        if (round % 7 === 3) { await client.call({ command: "undo", session: "s" }); await client.call({ command: "redo", session: "s" }); }
        // One replica stays offline for the first half; others have seeded random outages.
        if (!(index === 0 && round < rounds / 2) && random() > 0.45) await sync(index);
      }
    }
    // First flush every replica; second exchange distributes the final union to all.
    for (let pass = 0; pass < 2; pass++) for (let index = 0; index < replicas; index++) await sync(index);
    const documents = await Promise.all(clients.map(client => client.call({ command: "document", session: "s" })));
    const canonical = JSON.stringify(documents[0].blocks);
    if (!documents.every(doc => JSON.stringify(doc.blocks) === canonical)) throw new Error("Replicas diverged after rejoining");
    const final = await (await fetch(endpoint, { headers })).json();
    const observer = new NativeBridge(options.executable);
    try {
      const doc = await observer.call({ command: "restore", session: "s", actorID: "observer", snapshot: final });
      if (JSON.stringify(doc.blocks) !== canonical) throw new Error("Persisted server snapshot differs from clients");
    } finally { observer.close(); }
    if ("presence" in final) throw new Error("Presence leaked into persisted content");
    return { replicas, rounds, exchanges, seed: options.seed ?? 42, milliseconds: Math.round(performance.now() - start), documentBytes: canonical.length, converged: true };
  } finally { clients.forEach(client => client.close()); }
}

if (import.meta.main) console.log(JSON.stringify(await stressRelay({
  url: process.env.DEMO_URL ?? "http://127.0.0.1:4319", token: process.env.DEMO_TOKEN ?? "",
  executable: process.env.BLOCK_EDITOR_BRIDGE ?? "./.build/debug/editor-bridge",
  replicas: Number(process.env.STRESS_REPLICAS ?? 4), rounds: Number(process.env.STRESS_ROUNDS ?? 30), seed: Number(process.env.STRESS_SEED ?? 42),
}), null, 2));
