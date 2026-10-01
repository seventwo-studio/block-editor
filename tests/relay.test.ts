import { test, expect } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay } from "../demo/relay/server.ts";
import { stressRelay } from "../demo/relay/stress.ts";
import { NativeBridge } from "../demo/relay/bridge.ts";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { SwiftMergeRecoveryError } from "../src/swift.ts";

test("relay returns an unapplied recovery proposal and admits a client repair after server and client restart", async () => {
  const directory = await mkdtemp(join(tmpdir(), "editor-recovery-relay-"));
  const executable = process.env.BLOCK_EDITOR_BRIDGE ?? "./.build/debug/editor-bridge";
  const text = (text: string) => ({ type: "text" as const, text, marks: [] });
  const blocks = ["parent", "destination"].map(id => ({ id, type: "toggle" as const, summary: [text(id)], children: [] }));
  const options = { directory, executable, token: "test", port: 0, blocks, collaborationVersion: 2 as const };
  let relay = await startRelay(options);
  const clients = [new NativeBridge(executable), new NativeBridge(executable)];
  const headers = { "x-local-token": "test", "content-type": "application/json" };
  const call = (index: number, command: string, args: Record<string, unknown> = {}) => clients[index].call({ command, session: "recovery-client", ...args });
  const send = async (index: number) => await fetch(`${relay.url}/rooms/recovery`, { method: "POST", headers,
    body: JSON.stringify({ actorID: `author-${index}`, batch: await call(index, "changes"), state: await call(index, "syncState") }) });
  try {
    const baseline = await (await fetch(`${relay.url}/rooms/recovery`, { headers })).json();
    for (const index of [0, 1]) await call(index, "restore", { actorID: `author-${index}`, snapshot: baseline });
    const parent = await call(0, "node", { address: { blockID: "parent", path: [] } });
    const destination = await call(0, "node", { address: { blockID: "destination", path: [] } });
    const ids = [];
    for (const index of [0, 1]) ids.push((await call(index, "insertNode", {
      value: { id: "same", type: "paragraph", content: [text(`author ${index} 😀`)] },
      collection: { owner: parent, field: "children" },
    })).identity);
    const accepted = await send(0); expect(accepted.status).toBe(200);
    const saved = await readFile(join(directory, "recovery.json"), "utf8");
    const collision = await send(1); expect(collision.status).toBe(409);
    const error = await collision.json();
    expect(error.error).toBe("mergeRecoveryRequired"); expect(error.state).toBeUndefined();
    expect(error.recovery.reason).toBe("identityConflict");
    expect(error.recovery.batch.changes).toHaveLength(2);
    expect(await readFile(join(directory, "recovery.json"), "utf8")).toBe(saved);
    const ownSave = await call(1, "save"), ownState = await call(1, "syncState");
    await expect(call(1, "receive", { batch: error.recovery.batch })).rejects.toBeInstanceOf(SwiftMergeRecoveryError);
    expect(await call(1, "save")).toEqual(ownSave); expect(await call(1, "syncState")).toEqual(ownState);
    // Host storage retains transport recovery separately from its accepted draft.
    await clients[1].call({ command: "close", session: "recovery-client" }); clients[1].close();
    clients[1] = new NativeBridge(executable);
    await call(1, "restore", { actorID: "author-1", snapshot: JSON.parse(JSON.stringify(ownSave)) });
    await relay.close(); relay = await startRelay(options);
    expect(await (await fetch(`${relay.url}/rooms/recovery`, { headers })).json()).toEqual(JSON.parse(saved));
    await expect(call(1, "receive", { batch: JSON.parse(JSON.stringify(error.recovery.batch)) })).rejects.toBeInstanceOf(SwiftMergeRecoveryError);
    await call(1, "repairMerge", { repairs: [{ move: { identity: ids[1], collection: { owner: destination, field: "children" } } }] });
    expect(await call(1, "mergeRecovery")).toBeNull();
    const repaired = await send(1); expect(repaired.status).toBe(200);
    await call(1, "receive", { batch: (await repaired.json()).batch });
    const response = await send(0); expect(response.status).toBe(200);
    await call(0, "receive", { batch: (await response.json()).batch });
    expect((await call(0, "document")).blocks).toEqual((await call(1, "document")).blocks);
    expect(await call(1, "nodeAddress", { identity: ids[1] })).toEqual({ blockID: "destination", path: ["children", "same"] });
    const repairedSave = await readFile(join(directory, "recovery.json"), "utf8");
    expect(JSON.parse(repairedSave).changes).toHaveLength(3);
    // Undo Alice's insertion; Bob's repaired content remains. Duplicate resend is safe.
    await call(0, "undo"); expect((await send(0)).status).toBe(200);
    const bobResponse = await send(1); expect(bobResponse.status).toBe(200);
    await call(1, "receive", { batch: (await bobResponse.json()).batch });
    expect(JSON.stringify((await call(1, "document")).blocks)).toContain("author 1 😀");
    expect(JSON.stringify((await call(1, "document")).blocks)).not.toContain("author 0 😀");
    expect((await send(1)).status).toBe(200);
    const wrong = await fetch(`${relay.url}/rooms/recovery`, { method: "POST", headers,
      body: JSON.stringify({ actorID: "bad", batch: { ...baseline, version: 99 }, state: { received: [] } }) });
    expect(wrong.status).toBe(400); expect((await wrong.json()).recovery).toBeUndefined();
  } finally { clients.forEach(client => client.close()); await relay.close(); await rm(directory, { recursive: true, force: true }); }
}, 120_000);

test("versioned nested moves recover offline through the central relay and preserve remote author text", async () => {
  const directory = await mkdtemp(join(tmpdir(), "editor-nested-relay-"));
  const executable = process.env.BLOCK_EDITOR_BRIDGE ?? "./.build/debug/editor-bridge";
  const text = (text: string) => ({ type: "text" as const, text, marks: [] });
  const blocks = [
    { id: "left", type: "toggle" as const, summary: [text("Left")], children: [{ id: "p", type: "paragraph" as const, content: [text("base 😀")] }] },
    { id: "right", type: "toggle" as const, summary: [text("Right")], children: [] },
  ];
  const options = { directory, executable, token: "test", port: 0, blocks, collaborationVersion: 2 as const };
  let relay = await startRelay(options);
  const headers = { "x-local-token": "test", "content-type": "application/json" };
  const clients = [new NativeBridge(executable), new NativeBridge(executable)];
  const call = (index: number, command: string, args: Record<string, unknown> = {}) => clients[index].call({ command, session: "s", ...args });
  async function exchange(index: number) {
    const response = await fetch(`${relay.url}/rooms/nested`, { method: "POST", headers, body: JSON.stringify({
      actorID: `author-${index}`, batch: await call(index, "changes"), state: await call(index, "syncState"),
      presence: { actor: `author-${index}`, revision: 1 },
    }) });
    expect(response.status).toBe(200);
    const result = await response.json();
    await call(index, "receive", { batch: result.batch });
    return result;
  }
  try {
    const snapshot = await (await fetch(`${relay.url}/rooms/nested`, { headers })).json();
    for (const index of [0, 1]) await call(index, "restore", { actorID: `author-${index}`, snapshot });
    const identity = await call(0, "node", { address: { blockID: "left", path: ["children", "p"] } });
    const right = await call(0, "node", { address: { blockID: "right", path: [] } });
    const address = await call(0, "textAddress", { identity });
    // Both processes edit without exchanging or contacting the relay.
    await call(0, "moveNode", { identity, collection: { owner: right, field: "children" } });
    await call(0, "replaceText", { address, start: 0, end: 0, text: "LOCAL " });
    await call(1, "replaceText", { address, start: 7, end: 7, text: " REMOTE" });
    await exchange(0); await exchange(1); await exchange(0);
    expect((await call(0, "document")).blocks).toEqual((await call(1, "document")).blocks);
    expect(await call(0, "nodeAddress", { identity })).toEqual({ blockID: "right", path: ["children", "p"] });
    const saved = await readFile(join(directory, "nested.json"), "utf8");
    expect(JSON.parse(saved).version).toBe(2); expect(JSON.parse(saved).presence).toBeUndefined();
    await relay.close(); relay = await startRelay(options);
    await call(0, "undo"); await call(0, "undo");
    await exchange(0); await exchange(1);
    expect(await call(0, "nodeAddress", { identity })).toEqual({ blockID: "left", path: ["children", "p"] });
    const content = await call(0, "document");
    expect(JSON.stringify(content)).toContain("base 😀 REMOTE"); expect(JSON.stringify(content)).not.toContain("LOCAL");
    expect(content.blocks).toEqual((await call(1, "document")).blocks);
    expect((await call(0, "changes", { since: await call(1, "syncState") })).changes).toEqual([]);
  } finally { clients.forEach(client => client.close()); await relay.close(); await rm(directory, { recursive: true, force: true }); }
}, 120_000);

test("independent Swift processes converge through a persistent local relay after offline edits", async () => {
  const directory = await mkdtemp(join(tmpdir(), "editor-relay-"));
  const executable = process.env.BLOCK_EDITOR_BRIDGE ?? "./.build/debug/editor-bridge";
  let relay = await startRelay({ directory, executable, token: "test-token", port: 0 });
  const headers = { "x-local-token": "test-token", "content-type": "application/json" };
  try {
    expect((await fetch(`${relay.url}/rooms/test`)).status).toBe(401);
    const result = await stressRelay({ url: relay.url, token: "test-token", executable, rounds: 12, replicas: 4, room: "test", seed: 42 });
    expect(result.converged).toBe(true);
    expect(result.acknowledged).toBe(true);
    expect(result.partialExchanges).toBeGreaterThan(0);
    expect(result.restarts).toBe(8);
    for (const count of Object.values(result.attemptedOperations)) expect(count).toBeGreaterThan(0);
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

test("generated overlapping edits recover through the central relay for independent seeds", async () => {
  const directory = await mkdtemp(join(tmpdir(), "editor-generated-"));
  const executable = process.env.BLOCK_EDITOR_BRIDGE ?? "./.build/debug/editor-bridge";
  const relay = await startRelay({ directory, executable, token: "test", port: 0 });
  try {
    for (const seed of [1, 65537, 20260930]) {
      const result = await stressRelay({ url: relay.url, token: "test", executable, replicas: 4, rounds: 18, seed, room: `seed-${seed}` });
      expect(result.converged, `seed ${seed}`).toBe(true);
      expect(result.acknowledged, `seed ${seed}`).toBe(true);
      expect(result.partialExchanges, `seed ${seed}`).toBeGreaterThan(0);
      expect(result.restarts).toBe(12);
      for (const count of Object.values(result.attemptedOperations)) expect(count).toBeGreaterThan(0);
    }
  } finally { await relay.close(); await rm(directory, { recursive: true, force: true }); }
}, 120_000);

test("stress configuration rejects invalid counts and seeds before connecting", async () => {
  for (const invalid of [{ replicas: NaN }, { replicas: 2.5 }, { rounds: Infinity }, { rounds: 0 }, { seed: -1 }, { seed: NaN }, { seed: 2 ** 32 }]) {
    await expect(stressRelay({ url: "invalid", token: "", executable: "unused", ...invalid })).rejects.toThrow();
  }
});

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

test("native draft survives process restart with relay unavailable and preserves remote edits through undo", async () => {
  const directory = await mkdtemp(join(tmpdir(), "native-draft-"));
  const executable = process.env.BLOCK_EDITOR_BRIDGE ?? "./.build/debug/editor-bridge";
  let relay = await startRelay({ directory: join(directory, "relay"), executable, token: "test", port: 0 });
  let running = true;
  const endpoint = `${relay.url}/rooms/restart`, port = Number(new URL(relay.url).port);
  const draft = join(directory, "client.json");
  const run = async (options: Record<string, string>) => JSON.parse((await promisify(execFile)(".build/debug/relay-client", [], {
    env: { ...process.env, DEMO_ENDPOINT: endpoint, DEMO_TOKEN: "test", ...options },
  })).stdout);
  try {
    const offline = await run({ DEMO_DRAFT: draft, DEMO_OFFLINE: "1", DEMO_TEXT: " local-only 😀" });
    await relay.close(); running = false;
    const recovered = await run({ DEMO_DRAFT: draft, DEMO_OFFLINE: "1", DEMO_ACTION: "inspect", DEMO_TOKEN: "" });
    expect(recovered).toEqual(offline);
    relay = await startRelay({ directory: join(directory, "relay"), executable, token: "test", port }); running = true;
    await run({ DEMO_TEXT: " remote-only 世界" });
    const joined = await run({ DEMO_DRAFT: draft, DEMO_ACTION: "rejoin" });
    expect(JSON.stringify(joined)).toContain("local-only");
    expect(JSON.stringify(joined)).toContain("remote-only");
    const undone = await run({ DEMO_DRAFT: draft, DEMO_ACTION: "undo" });
    expect(JSON.stringify(undone)).not.toContain("local-only");
    expect(JSON.stringify(undone)).toContain("remote-only");
  } finally { if (running) await relay.close(); await rm(directory, { recursive: true, force: true }); }
});
