import { test, expect } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay } from "../demo/relay/server.ts";
import { stressRelay } from "../demo/relay/stress.ts";
import { NativeBridge } from "../demo/relay/bridge.ts";

test("independent Swift processes converge through a persistent local relay after offline edits", async () => {
  const directory = await mkdtemp(join(tmpdir(), "editor-relay-"));
  const executable = process.env.BLOCK_EDITOR_BRIDGE ?? "./.build/debug/editor-bridge";
  let relay = await startRelay({ directory, executable, token: "test-token", port: 0 });
  const headers = { "x-local-token": "test-token", "content-type": "application/json" };
  try {
    expect((await fetch(`${relay.url}/rooms/test`)).status).toBe(401);
    const result = await stressRelay({ url: relay.url, token: "test-token", executable, rounds: 12, replicas: 4, room: "test", seed: 42 });
    expect(result.converged).toBe(true);
    const saved = await readFile(join(directory, "test.json"), "utf8");
    expect(JSON.parse(saved).presence).toBeUndefined();
    await relay.close();
    relay = await startRelay({ directory, executable, token: "test-token", port: 0 });
    const snapshot = await (await fetch(`${relay.url}/rooms/test`, { headers })).json();
    expect(snapshot).toEqual(JSON.parse(saved));
    const bad = await fetch(`${relay.url}/rooms/test`, { method: "POST", headers, body: JSON.stringify({ actorID: "bad", batch: { ...snapshot, version: 99 }, state: { received: [] } }) });
    expect(bad.status).toBe(400);
    expect(await readFile(join(directory, "test.json"), "utf8")).toBe(saved);
  } finally { await relay.close(); await rm(directory, { recursive: true, force: true }); }
}, 120_000);

test("presence expires, rejects stale revisions and leaves saved content unchanged", async () => {
  const directory = await mkdtemp(join(tmpdir(), "editor-presence-"));
  const executable = process.env.BLOCK_EDITOR_BRIDGE ?? "./.build/debug/editor-bridge";
  const client = new NativeBridge(executable);
  let now = 1000;
  let relay = await startRelay({ directory, executable, token: "test", port: 0, presenceTTL: 5000, now: () => now });
  const headers = { "x-local-token": "test", "content-type": "application/json" };
  try {
    const snapshot = await (await fetch(`${relay.url}/rooms/presence`, { headers })).json();
    await client.call({ command: "restore", session: "s", actorID: "observer", snapshot });
    const batch = await client.call({ command: "changes", session: "s" });
    const state = await client.call({ command: "syncState", session: "s" });
    async function exchange(actorID: string, presence?: unknown) {
      const response = await fetch(`${relay.url}/rooms/presence`, { method: "POST", headers,
        body: JSON.stringify({ actorID, batch, state, presence }) });
      expect(response.status).toBe(200);
      return await response.json();
    }
    const alice = { actor: "alice", revision: 2, address: { blockID: "p", path: ["content"] },
      anchor: { change: { counter: 1, actor: "alice" }, index: 0 },
      focus: { change: { counter: 1, actor: "alice" }, index: 2 } };
    expect((await exchange("alice", alice)).presence).toEqual([alice]);
    const saved = await readFile(join(directory, "presence.json"), "utf8");
    now += 1000;
    expect((await exchange("alice", { ...alice, revision: 1 })).presence).toEqual([alice]);
    now = 6000; // Stale packets must not extend Alice's lease.
    expect((await exchange("observer")).presence).toEqual([]);
    expect((await exchange("alice", { ...alice, revision: 3 })).presence).toHaveLength(1);
    expect((await exchange("alice", null)).presence).toEqual([]);
    await exchange("alice", { ...alice, revision: 4 });
    expect(await readFile(join(directory, "presence.json"), "utf8")).toBe(saved);
    await relay.close();
    relay = await startRelay({ directory, executable, token: "test", port: 0 });
    expect((await exchange("observer")).presence).toEqual([]);
    expect(await readFile(join(directory, "presence.json"), "utf8")).toBe(saved);
  } finally { client.close(); await relay.close(); await rm(directory, { recursive: true, force: true }); }
});
