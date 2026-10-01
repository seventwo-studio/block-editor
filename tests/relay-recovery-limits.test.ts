import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { NativeBridge } from "../demo/relay/bridge.ts";
import { startRelay } from "../demo/relay/server.ts";

test("transport capacity rejects without receipts and the author archive survives restart", async () => {
  const directory = await mkdtemp(join(tmpdir(), "editor-transport-capacity-"));
  const executable = process.env.BLOCK_EDITOR_BRIDGE ?? "./.build/debug/editor-bridge";
  const options = { directory, executable, token: "test", port: 0, blocks: [], collaborationVersion: 2 as const };
  let relay = await startRelay(options);
  let client = new NativeBridge(executable);
  const headers = { "x-local-token": "test", "content-type": "application/json" };
  const call = (command: string, args: Record<string, unknown> = {}) => client.call({ command, session: "author", ...args });
  let presenceRevision = 1;
  try {
    const baseline = await (await fetch(`${relay.url}/rooms/capacity`, { headers })).json();
    await call("restore", { actorID: "writer", snapshot: baseline });
    const exchange = async () => fetch(`${relay.url}/rooms/capacity`, { method: "POST", headers, body: JSON.stringify({
      actorID: "writer", batch: await call("changes"), state: await call("syncState"), presence: { actor: "writer", revision: presenceRevision },
    }) });
    expect((await exchange()).status).toBe(200);
    const serverBefore = await readFile(join(directory, "capacity.json"), "utf8");
    await call("insertNode", { collection: { field: "blocks" }, value: { id: "large", type: "host-extension", blob: "x".repeat(8_000_000) } });
    const accepted = await call("save"), receipts = await call("syncState"), outgoing = await call("changes");
    presenceRevision = 2;
    const rejected = await exchange();
    expect(rejected.status).toBe(413);
    const failure = await rejected.json();
    expect(failure.error).toBe("transportCapacityExceeded");
    expect(failure.maxBytes).toBe(8_000_000);
    expect(failure.state).toBeUndefined(); expect(failure.batch).toBeUndefined(); expect(failure.presence).toBeUndefined();
    expect(await readFile(join(directory, "capacity.json"), "utf8")).toBe(serverBefore);
    expect(await call("save")).toEqual(accepted); expect(await call("syncState")).toEqual(receipts);
    const observer = await fetch(`${relay.url}/rooms/capacity`, { method: "POST", headers, body: JSON.stringify({
      actorID: "observer", batch: baseline, state: { received: [] }, presence: null,
    }) });
    expect(observer.status).toBe(200);
    expect((await observer.json()).presence).toEqual([{ actor: "writer", revision: 1 }]);
    // The rejected request remains an owned archive, separate from server history.
    const archive = join(directory, "unacknowledged.json");
    await writeFile(archive, JSON.stringify({ accepted, outgoing }));
    client.close(); client = new NativeBridge(executable);
    await relay.close(); relay = await startRelay(options);
    const reopened = JSON.parse(await readFile(archive, "utf8"));
    await call("restore", { actorID: "writer", snapshot: reopened.accepted });
    expect(await call("changes")).toEqual(reopened.outgoing);
    expect(await call("syncState")).toEqual(receipts);
    expect(await (await fetch(`${relay.url}/rooms/capacity`, { headers })).json()).toEqual(JSON.parse(serverBefore));
    expect((await exchange()).status).toBe(413);
    expect(await readFile(join(directory, "capacity.json"), "utf8")).toBe(serverBefore);
    expect((await call("document")).blocks[0].blob.length).toBe(8_000_000);
  } finally { client.close(); await relay.close(); await rm(directory, { recursive: true, force: true }); }
}, 120_000);

test("relay admits exactly 8 MB and rejects the next byte without changing accepted state", async () => {
  const directory = await mkdtemp(join(tmpdir(), "editor-transport-boundary-"));
  const executable = process.env.BLOCK_EDITOR_BRIDGE ?? "./.build/debug/editor-bridge";
  const relay = await startRelay({ directory, executable, token: "test", port: 0, blocks: [], collaborationVersion: 2 });
  const headers = { "x-local-token": "test", "content-type": "application/json" };
  try {
    const endpoint = `${relay.url}/rooms/boundary`;
    const batch = await (await fetch(endpoint, { headers })).json();
    const input = { actorID: "boundary-writer", batch, state: { received: [] }, padding: "" };
    const overhead = Buffer.byteLength(JSON.stringify(input));
    const exact = JSON.stringify({ ...input, padding: "x".repeat(8_000_000 - overhead) });
    expect(Buffer.byteLength(exact)).toBe(8_000_000);
    const admitted = await fetch(endpoint, { method: "POST", headers, body: exact });
    expect(admitted.status).toBe(200);
    const acceptedState = (await admitted.json()).state;
    const acceptedFile = await readFile(join(directory, "boundary.json"), "utf8");
    const oversized = JSON.stringify({ ...input, padding: "x".repeat(8_000_001 - overhead) });
    expect(Buffer.byteLength(oversized)).toBe(8_000_001);
    const rejected = await fetch(endpoint, { method: "POST", headers, body: oversized });
    expect(rejected.status).toBe(413);
    expect(await rejected.json()).toEqual({ error: "transportCapacityExceeded", maxBytes: 8_000_000 });
    expect(await readFile(join(directory, "boundary.json"), "utf8")).toBe(acceptedFile);
    const retry = await fetch(endpoint, { method: "POST", headers, body: JSON.stringify(input) });
    expect(retry.status).toBe(200);
    expect((await retry.json()).state).toEqual(acceptedState);
    expect(await readFile(join(directory, "boundary.json"), "utf8")).toBe(acceptedFile);
  } finally { await relay.close(); await rm(directory, { recursive: true, force: true }); }
}, 120_000);
