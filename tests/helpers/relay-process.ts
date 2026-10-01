import { expect, type BrowserContext, type BrowserType, type Page, type TestInfo } from "@playwright/test";
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { createInterface } from "node:readline";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { Block } from "../../src/schema.ts";

export const executable = resolve(process.env.BLOCK_EDITOR_BRIDGE ?? ".build/debug/editor-bridge");
export const token = "relay-process-test";
export const headers = { "x-local-token": token, "content-type": "application/json" };

async function relayProcess(directory: string, blocks?: Block[], collaborationVersion: 1 | 2 = 1) {
  const child = spawn(process.env.BUN_BIN ?? "bun", ["scripts/relay-process-fixture.ts"], {
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, RELAY_PROCESS_OPTIONS: JSON.stringify({ executable, directory, token, port: 0, blocks, collaborationVersion }) },
  });
  let stderr = "";
  child.stderr.on("data", chunk => { stderr += chunk; });
  const exited = new Promise<number | null>(resolve => child.once("exit", resolve));
  const ready = await new Promise<{ url: string; pid: number }>((resolve, reject) => {
    const lines = createInterface({ input: child.stdout });
    const timer = setTimeout(() => { child.kill(); reject(new Error(`Relay startup timed out: ${stderr}`)); }, 15_000);
    lines.once("line", line => {
      clearTimeout(timer); lines.close();
      try { resolve(JSON.parse(line)); } catch (error) { child.kill(); reject(error); }
    });
    child.once("error", error => { clearTimeout(timer); reject(error); });
    child.once("exit", code => { clearTimeout(timer); reject(new Error(`Relay exited (${code}): ${stderr}`)); });
  });
  return { ...ready, async stop() {
    child.kill("SIGTERM");
    const timer = setTimeout(() => child.kill("SIGKILL"), 10_000);
    try { expect(await exited, stderr).toBe(0); } finally { clearTimeout(timer); }
  } };
}

export async function readDraft(page: Page, key: string) {
  return page.evaluate(async key => {
    const database = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open("block-editor-local-lab", 2);
      request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
    try { return await new Promise<any>((resolve, reject) => {
      const request = database.transaction("drafts").objectStore("drafts").get(key);
      request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    }); } finally { database.close(); }
  }, key);
}

export async function processLab(browserType: BrowserType, testInfo: TestInfo) {
  const directory = await mkdtemp(join(tmpdir(), "editor-browser-process-"));
  const profile = join(directory, "profile");
  let relay: Awaited<ReturnType<typeof relayProcess>> | undefined;
  let context: BrowserContext | undefined;
  let launcherPid: number | undefined;
  const phases: Array<Record<string, unknown>> = [];
  const shellQuote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
  const wrapper = join(directory, "browser-launcher.sh"), pidFile = join(directory, "browser.pid");
  await writeFile(wrapper, `#!/bin/sh\nprintf '%s\\n' "$$" > ${shellQuote(pidFile)}\nexec ${shellQuote(browserType.executablePath())} "$@"\n`, { mode: 0o700 });
  let relayRequests = 0;
  const baseURL = testInfo.project.use.baseURL!;
  return {
    phases,
    get requests() { return relayRequests; },
    get url() { if (!relay) throw new Error("Relay is stopped"); return relay.url; },
    async startServer(blocks?: Block[], version: 1 | 2 = 1) {
      relay = await relayProcess(join(directory, "relay"), blocks, version);
      phases.push({ phase: "relay-start", pid: relay.pid, version });
    },
    async stopServer() {
      if (!relay) return;
      const stopped = relay; relay = undefined;
      await stopped.stop(); phases.push({ phase: "relay-exit", pid: stopped.pid, exitCode: 0 });
    },
    async savedRoom(room: string) { return readFile(join(directory, "relay", `${room}.json`), "utf8"); },
    async launch() {
      context = await browserType.launchPersistentContext(profile, { executablePath: wrapper, headless: true, baseURL, acceptDownloads: true });
      const pid = Number((await readFile(pidFile, "utf8")).trim());
      expect(pid).toBeGreaterThan(0);
      launcherPid = pid;
      phases.push({ phase: "browser-start", launcherPid: pid, version: context.browser()?.version() });
      await context.route("**/relay/rooms/**", async route => {
        relayRequests++;
        if (!relay) { await route.abort(); return; }
        const response = await route.fetch({ url: `${relay.url}${new URL(route.request().url()).pathname.replace(/^\/relay/, "")}` });
        phases.push({ phase: "relay-response", status: response.status() });
        await route.fulfill({ response });
      });
      return context;
    },
    async closeBrowser() {
      if (!context) return;
      const closed = context; context = undefined;
      const browser = closed.browser();
      await closed.close();
      expect(browser?.isConnected()).toBe(false);
      await expect.poll(() => {
        try { process.kill(launcherPid!, 0); return false; }
        catch (error) { if ((error as NodeJS.ErrnoException).code === "ESRCH") return true; throw error; }
      }).toBe(true);
      phases.push({ phase: "browser-exit", launcherPid, disconnected: true, processExited: true });
    },
    async report() {
      const hash = async (path: string) => createHash("sha256").update(await readFile(path)).digest("hex");
      const sourceRevision = (await promisify(execFile)("git", ["rev-parse", "HEAD"])).stdout.trim();
      if (process.env.EVIDENCE_SOURCE_SHA) expect(process.env.EVIDENCE_SOURCE_SHA).toBe(sourceRevision);
      const sourcePaths = ["tests/helpers/relay-process.ts", "tests/relay-process-restart.spec.ts", "scripts/relay-process-fixture.ts",
        "demo/local-main.tsx", "demo/local-storage.ts", "demo/local-sync.ts", "demo/relay/server.ts", "src/swift.ts"];
      const sourceFiles = Object.fromEntries(await Promise.all(sourcePaths.map(async path => [path, await hash(path)])));
      const runtimeManifest = process.env.EVIDENCE_RUNTIME_MANIFEST
        ? JSON.parse(await readFile(process.env.EVIDENCE_RUNTIME_MANIFEST, "utf8")) : null;
      await testInfo.attach("process-restart-evidence", { contentType: "application/json", body: JSON.stringify({
        sourceRevision,
        sourceFiles, runtimeManifest,
        platform: process.platform, architecture: process.arch,
        browser: browserType.name(), bridgeSHA256: await hash(executable), wasmSHA256: await hash("demo/public/block-editor.wasm"),
        phases, relayRequests,
      }, null, 2) });
    },
    async cleanup() {
      if (context) await context.close();
      if (relay) await relay.stop();
      await rm(directory, { recursive: true, force: true });
    },
  };
}

export async function reopen(context: BrowserContext, room: string, client: string) {
  const page = await context.newPage();
  await page.goto("local.html");
  await page.getByLabel("Room", { exact: true }).fill(room);
  await page.getByLabel("Saved local draft").selectOption(client);
  await page.getByRole("button", { name: "Open editor" }).click();
  await expect(page.getByLabel("Local demo token")).toHaveValue("");
  await expect(page.getByLabel("Connected to local server")).not.toBeChecked();
  await expect(page.getByTestId("local-save")).toHaveText("Saved locally");
  return page;
}
