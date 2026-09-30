import { createServer, type IncomingMessage } from "node:http";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { NativeBridge } from "./bridge.ts";
import type { Block } from "../../src/schema.ts";

const initialBlocks = [{ id: "p", type: "paragraph", content: [{ type: "text", text: "Shared local document", marks: [] }] }];
const MAX_BODY = 8_000_000;

async function body(request: IncomingMessage) {
  const chunks: Buffer[] = [];
  let count = 0;
  for await (const chunk of request) {
    count += chunk.length;
    if (count > MAX_BODY) throw new Error("Request exceeds 8 MB");
    chunks.push(Buffer.from(chunk));
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

/** Local testing service only. Loopback binding, explicit token, no CORS or cloud services. */
export async function startRelay(options: { executable: string; directory: string; token: string; port?: number; presenceTTL?: number; now?: () => number; blocks?: Block[]; collaborationVersion?: 1 | 2 }) {
  if (!options.token) throw new Error("A local demo token is required");
  await mkdir(options.directory, { recursive: true });
  const bridge = new NativeBridge(options.executable);
  const opened = new Set<string>();
  const presence = new Map<string, Map<string, { value: any; expires: number }>>();
  let tail: Promise<unknown> = Promise.resolve();
  let exchanges = 0;
  async function room(id: string) {
    if (opened.has(id)) return;
    let snapshot;
    try { snapshot = JSON.parse(await readFile(join(options.directory, `${id}.json`), "utf8")); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    if (snapshot) {
      if (options.collaborationVersion !== undefined && snapshot.version !== options.collaborationVersion) throw new Error("Relay protocol differs from its saved room; use an explicit cutover");
      await bridge.call({ command: "restore", session: id, actorID: "relay", snapshot });
    } else await bridge.call({ command: "create", session: id, actorID: "relay", documentID: id,
      blocks: options.blocks ?? initialBlocks, collaborationVersion: options.collaborationVersion ?? 1 });
    opened.add(id);
  }
  const server = createServer((request, response) => {
    const execute = async () => {
      response.setHeader("Content-Type", "application/json");
      response.setHeader("Cache-Control", "no-store");
      if (request.headers["x-local-token"] !== options.token) {
        response.writeHead(401).end(JSON.stringify({ error: "Local demo token required" })); return;
      }
      const match = /^\/rooms\/([A-Za-z0-9_-]{1,80})$/.exec(request.url ?? "");
      if (!match || !["GET", "POST"].includes(request.method ?? "")) {
        response.writeHead(404).end(JSON.stringify({ error: "Unknown endpoint" })); return;
      }
      const id = match[1];
      await room(id);
      if (request.method === "GET") {
        response.end(JSON.stringify(await bridge.call({ command: "save", session: id }))); return;
      }
      const input = await body(request);
      if (!input || !input.batch || !input.state || typeof input.actorID !== "string") throw new Error("Invalid exchange");
      // Swift atomically validates the protocol, baseline and all changes before acknowledgement.
      await bridge.call({ command: "receive", session: id, batch: input.batch });
      const snapshot = await bridge.call({ command: "save", session: id });
      const file = join(options.directory, `${id}.json`);
      await writeFile(file + ".tmp", JSON.stringify(snapshot));
      await rename(file + ".tmp", file);
      const now = (options.now ?? Date.now)(), peers = presence.get(id) ?? new Map();
      presence.set(id, peers);
      for (const [actor, entry] of peers) if (entry.expires <= now) peers.delete(actor);
      if (input.presence === null) peers.delete(input.actorID);
      else if (input.presence && input.presence.actor === input.actorID && Number.isSafeInteger(input.presence.revision)) {
        const previous = peers.get(input.actorID);
        if (!previous || previous.value.revision <= input.presence.revision)
          peers.set(input.actorID, { value: input.presence, expires: now + (options.presenceTTL ?? 5000) });
      }
      exchanges++;
      response.end(JSON.stringify({
        batch: await bridge.call({ command: "changes", session: id, since: input.state }),
        state: await bridge.call({ command: "syncState", session: id }),
        presence: [...peers.values()].map(entry => entry.value), exchanges,
      }));
    };
    // Serializes each complete receive/save/ack transaction, not merely individual bridge calls.
    tail = tail.then(execute).catch(error => {
      if (!response.headersSent) response.writeHead(400);
      response.end(JSON.stringify({ error: String(error) }));
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port ?? 4319, "127.0.0.1", resolve);
  });
  const address = server.address();
  const url = `http://127.0.0.1:${typeof address === "object" && address ? address.port : options.port}`;
  return { url, async close() {
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    await tail; bridge.close();
  } };
}
