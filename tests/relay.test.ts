import { test, expect } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay } from "../demo/relay/server.ts";
import { stressRelay } from "../demo/relay/stress.ts";

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
