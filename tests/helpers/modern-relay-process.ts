import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { resolve } from "node:path";
import type { ModernRelayRoomTemplate } from "../../demo/relay/modern-room.ts";
import { encodeModernBridgeJSON } from "../../src/swift-modern-json.ts";

/** Separate server process; stop waits for server and its native bridge exit. */
export async function modernRelayProcess(directory: string, modern: ModernRelayRoomTemplate) {
  const child = spawn(process.env.BUN_BIN ?? "bun", ["scripts/relay-process-fixture.ts"], { stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, RELAY_PROCESS_OPTIONS: encodeModernBridgeJSON({ executable: resolve(process.env.BLOCK_EDITOR_BRIDGE ?? ".build/debug/editor-bridge"), directory,
      modern, token: "modern-relay-test", port: 0 }) } });
  let stderr = ""; child.stderr.on("data", bytes => { stderr += bytes; });
  const exited = new Promise<number | null>(resolve => child.once("exit", resolve));
  const ready = await new Promise<{ url: string; pid: number }>((resolve, reject) => {
    const lines = createInterface({ input: child.stdout });
    const timeout = setTimeout(() => { child.kill(); reject(new Error(`Modern relay startup timed out: ${stderr}`)); }, 15_000);
    lines.once("line", line => { clearTimeout(timeout); lines.close(); try { resolve(JSON.parse(line)); } catch (error) { child.kill(); reject(error); } });
    child.once("error", error => { clearTimeout(timeout); reject(error); });
    child.once("exit", code => { clearTimeout(timeout); reject(new Error(`Modern relay stopped (${code}): ${stderr}`)); });
  });
  return { ...ready, async stop() {
    child.kill("SIGTERM"); const timeout = setTimeout(() => child.kill("SIGKILL"), 10_000);
    try { const code = await exited; if (code !== 0) throw new Error(`Modern relay exit ${code}: ${stderr}`); }
    finally { clearTimeout(timeout); }
  } };
}
