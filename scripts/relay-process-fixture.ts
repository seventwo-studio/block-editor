import { startRelay } from "../demo/relay/server.ts";
import { writeFile, rename } from "node:fs/promises";

// Test-only subprocess: a restart discards all relay/bridge memory while keeping
// the supplied directory. The reference relay remains loopback-only.
const options = JSON.parse(process.env.RELAY_PROCESS_OPTIONS ?? "{}");
const relay = await startRelay(options);
// Native automation waits for this test-only readiness receipt rather than
// synchronously reading a pipe on the editor's main actor.
if (process.env.RELAY_READY_FILE) {
  const file = process.env.RELAY_READY_FILE;
  await writeFile(`${file}.tmp`, JSON.stringify({ url: relay.url, pid: process.pid }), { flag: "wx", mode: 0o600 });
  await rename(`${file}.tmp`, file);
}
console.log(JSON.stringify({ url: relay.url, pid: process.pid }));
let stopping = false;
for (const signal of ["SIGINT", "SIGTERM"] as const) process.once(signal, async () => {
  if (stopping) return;
  stopping = true;
  await relay.close();
  process.exit(0);
});
