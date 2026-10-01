import { mkdir, mkdtemp, readFile, readdir, rename, rm, statfs, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { join, relative, resolve } from "node:path";
import { tmpdir } from "node:os";
import { startRelay } from "../demo/relay/server.ts";
import { NativeBridge } from "../demo/relay/bridge.ts";

// Run only after an explicit build/foreground reservation. Reuse installed SDKs.
const [simulator, derivedData, buildFlag] = process.argv.slice(2);
const executable = process.env.BLOCK_EDITOR_BRIDGE;
if (!simulator || !derivedData || !executable) throw new Error("Pass simulator UDID, existing derived-data path and BLOCK_EDITOR_BRIDGE; add --build only in the reserved build slot");
if (buildFlag && buildFlag !== "--build") throw new Error("Unsupported option");
const capacity = await statfs(process.cwd());
if (capacity.bavail * capacity.bsize < 500 * 1024 * 1024) throw new Error("Preserve the shared 500 MiB disk reserve before native capacity execution");
const evidence = resolve(process.env.CAPACITY_OUTPUT ?? "test-results/apple-capacity");
await mkdir(evidence, { recursive: true });
const directory = await mkdtemp(join(tmpdir(), "apple-capacity-"));
const token = randomUUID(), room = `capacity-${randomUUID()}`, draftID = randomUUID().toUpperCase(), actor = randomUUID();
const bundle = "studio.seventwo.blockeditor.lab.EditorLab-iOS";
const phases: Record<string, unknown>[] = [];
const text = (value: string) => ({ type: "text" as const, text: value, marks: [] });
const blocks = [{ id: "p", type: "paragraph" as const, content: [text("Retained café 😀")] }];
const headers = { "content-type": "application/json", "x-local-token": token };
const bridge = new NativeBridge(executable);
const hash = async (path: string) => createHash("sha256").update(await readFile(path)).digest("hex");
const app = join(derivedData, "Build/Products/Debug-iphonesimulator/EditorLab-iOS.app");
const appExecutable = join(app, "EditorLab-iOS");
const testRunner = join(derivedData, "Build/Products/Debug-iphonesimulator/EditorLab-UITests-Runner.app");
const qualificationFile = join(derivedData, "st96-capacity-build.json");
let qualification: unknown;
let relay: Awaited<ReturnType<typeof startRelay>> | undefined;
let control: ReturnType<typeof Bun.serve> | undefined;
let proxy: ReturnType<typeof Bun.serve> | undefined;
let currentPhase = "setup", activePosts = 0, nextPost = 0;
type PostObservation = { sequence: number; phase: string; completed: boolean; status: number; authenticated: boolean; requestBytes: number; responseSHA256: string; capacityError: boolean };
const posts: PostObservation[] = [];
const retryAttempts: Array<{ id: string; phase: string; afterSequence: number; completion?: PostObservation }> = [];
let draftFile: string | undefined, backup: string | undefined;
const call = (command: string, args: Record<string, unknown> = {}) => bridge.call({ command, session: "seed", ...args });
async function run(command: string[], env = process.env, log?: string): Promise<string> {
  const child = Bun.spawn(command, { env, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()]);
  const result = stdout + stderr;
  if (log) await writeFile(log, result);
  if (await child.exited !== 0) throw new Error(`${command[0]} failed: ${result.slice(-8000)}`);
  return result;
}
async function sourceHashes() {
  const sources: Record<string, string> = {};
  async function visit(directory: string) {
    for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await visit(path);
      else if (entry.name.endsWith(".swift")) sources[relative(process.cwd(), path)] = await hash(path);
    }
  }
  await visit("Sources"); await visit("Examples/AppleDemo/UITests");
  for (const path of ["Package.swift", "Examples/AppleDemo/project.yml", "Examples/AppleDemo/EditorLabApp.swift"])
    sources[path] = await hash(path);
  return sources;
}
async function productHashes() {
  const products: Record<string, string> = {};
  async function visit(directory: string) {
    for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await visit(path);
      else if (entry.isFile()) products[relative(derivedData, path)] = await hash(path);
    }
  }
  await visit(app); await visit(testRunner);
  return products;
}
async function reserve() {
  const free = await statfs(process.cwd());
  if (free.bavail * free.bsize < 500 * 1024 * 1024) throw new Error("Native campaign reached the shared 500 MiB reserve; stop and release the resource slot");
}
async function drainPosts() {
  const deadline = Date.now() + 10_000;
  while (activePosts && Date.now() < deadline) await Bun.sleep(25);
  if (activePosts) throw new Error("Started relay POSTs did not settle");
}
async function restoreStorage() {
  if (!backup || !draftFile) return;
  await rm(draftFile, { recursive: true });
  await rename(backup, draftFile); backup = undefined;
}
try {
  const options = { directory: join(directory, "relay"), executable, token, port: 0, blocks, collaborationVersion: 2 as const };
  relay = await startRelay(options);
  const upstream = `${relay.url}/rooms/${room}`, port = Number(new URL(relay.url).port);
  const baseline = await (await fetch(upstream, { headers })).json();
  const admitted = await fetch(upstream, { method: "POST", headers, body: JSON.stringify({ actorID: "observer", batch: baseline, state: { received: [] }, presence: null }) });
  if (admitted.status !== 200) throw new Error("Baseline not admitted");
  proxy = Bun.serve({ hostname: "127.0.0.1", port: 0, maxRequestBodySize: 130_000_000, async fetch(request) {
    if (request.method !== "POST" || new URL(request.url).pathname !== `/rooms/${room}`) return new Response("Unknown route", { status: 404 });
    const sequence = ++nextPost, phase = currentPhase;
    const authenticated = request.headers.get("x-local-token") === token;
    const observation: PostObservation = { sequence, phase, authenticated, completed: false, status: 0, requestBytes: 0, responseSHA256: "", capacityError: false };
    posts.push(observation); activePosts++;
    try {
      const body = await request.arrayBuffer(); observation.requestBytes = body.byteLength;
      const response = await fetch(upstream, { method: "POST", headers: request.headers, body });
      const responseBody = await response.text();
      let capacityError = false;
      try { const error = JSON.parse(responseBody); capacityError = error.error === "transportCapacityExceeded" && error.maxBytes === 8_000_000; } catch { /* Preserve unexpected responses as failed observations. */ }
      Object.assign(observation, { status: response.status, responseSHA256: createHash("sha256").update(responseBody).digest("hex"), capacityError });
      return new Response(responseBody, { status: response.status, headers: response.headers });
    } catch {
      observation.status = 503;
      return new Response("Relay unavailable", { status: 503 });
    } finally { observation.completed = true; activePosts--; }
  } });
  const endpoint = `${proxy.url.toString().replace(/\/$/, "")}/rooms/${room}`;
  const serverBefore = await readFile(join(directory, "relay", `${room}.json`), "utf8");
  await writeFile(join(evidence, "accepted-server-before.json"), serverBefore);
  await call("restore", { actorID: actor, snapshot: baseline });
  await call("insertNode", { collection: { field: "blocks" }, value: { id: "large", type: "host-extension", blob: "x".repeat(8_000_000) } });
  const snapshot = await call("save");
  let retainedSnapshot = snapshot;
  const buildArguments = ["xcodebuild", "-project", "Examples/AppleDemo/EditorLab.xcodeproj", "-scheme", "EditorLab-iOS",
    "-destination", `platform=iOS Simulator,id=${simulator}`, "-derivedDataPath", derivedData,
    "-collect-test-diagnostics", "never", "CODE_SIGNING_ALLOWED=NO"];
  const sources = await sourceHashes();
  await writeFile(join(evidence, "source-hashes.json"), JSON.stringify(sources, null, 2));
  if (buildFlag) {
    await run(["xcodegen", "generate", "--spec", "Examples/AppleDemo/project.yml"]);
    await run([...buildArguments, "build-for-testing"], process.env, join(evidence, "build.txt"));
    if (JSON.stringify(sources) !== JSON.stringify(await sourceHashes())) throw new Error("Capacity sources changed during the build");
    qualification = { sources, products: await productHashes(), appExecutableSHA256: await hash(appExecutable), buildArguments };
    await writeFile(qualificationFile, JSON.stringify(qualification, null, 2));
  } else {
    const cached = JSON.parse(await readFile(qualificationFile, "utf8"));
    if (JSON.stringify(cached.sources) !== JSON.stringify(sources) || JSON.stringify(cached.products) !== JSON.stringify(await productHashes()))
      throw new Error("Cached app is not qualified for these capacity campaign sources; rebuild in the reserved slot");
    qualification = cached;
  }
  await reserve();
  await run(["xcrun", "simctl", "install", simulator, app]);
  const container = (await run(["xcrun", "simctl", "get_app_container", simulator, bundle, "data"])).trim();
  let root = join(container, "Library/Application Support/BlockEditorLocalLab");
  await mkdir(root, { recursive: true });
  draftFile = join(root, `${draftID}.json`);
  await writeFile(draftFile, JSON.stringify({ version: 2, endpoint, actorID: actor,
    snapshot: Buffer.from(JSON.stringify(snapshot)).toString("base64"), purpose: "draft" }), { flag: "wx" });
  const exportsBefore = new Set(await readdir(root));
  const exportsSeen = new Set(exportsBefore);
  async function refreshDraftLocation() {
    // XCTest may reinstall the app and migrate its data to another container.
    const current = (await run(["xcrun", "simctl", "get_app_container", simulator, bundle, "data"])).trim();
    root = join(current, "Library/Application Support/BlockEditorLocalLab");
    draftFile = join(root, `${draftID}.json`);
    const saved = JSON.parse(await readFile(draftFile, "utf8"));
    if (saved.actorID !== actor) throw new Error("Task-owned draft writer changed during container migration");
  }
  control = Bun.serve({ hostname: "127.0.0.1", port: 0, idleTimeout: 30, async fetch(request) {
    if (request.method !== "POST" || request.headers.get("x-test-token") !== token) return new Response("Denied", { status: 403 });
    const action = new URL(request.url).pathname;
    if (action === "/arm-retry") {
      try { await drainPosts(); } catch { return new Response("Previous POST did not settle", { status: 409 }); }
      const attempt = { id: randomUUID(), phase: currentPhase, afterSequence: nextPost };
      retryAttempts.push(attempt);
      return Response.json(attempt);
    }
    if (action === "/await-retry") {
      const { id } = await request.json() as { id?: string };
      const attempt = retryAttempts.find(attempt => attempt.id === id && attempt.phase === currentPhase);
      if (!attempt) return new Response("Unknown retry attempt", { status: 400 });
      const deadline = Date.now() + 10_000;
      while (Date.now() < deadline) {
        const completion = posts.find(post => post.sequence > attempt.afterSequence && post.phase === attempt.phase
          && post.completed && post.authenticated && post.status === 413 && post.capacityError);
        if (completion) { attempt.completion = completion; return Response.json(attempt); }
        await Bun.sleep(25);
      }
      return new Response("Retry produced no additional authenticated completed 413 POST", { status: 408 });
    }
    if (action === "/block" && !backup && draftFile) {
      await refreshDraftLocation();
      backup = draftFile + ".capacity-test-backup";
      await rename(draftFile, backup); await mkdir(draftFile);
      return new Response("Blocked task-owned draft destination");
    }
    if (action === "/restore") { await restoreStorage(); return new Response("Restored task-owned draft destination"); }
    return new Response("Unknown test action", { status: 400 });
  } });
  async function inspect(phase: string) {
    await drainPosts();
    await refreshDraftLocation();
    const saved = JSON.parse(await readFile(draftFile!, "utf8"));
    const accepted = JSON.parse(Buffer.from(saved.snapshot, "base64").toString());
    if (saved.actorID !== actor || saved.recovery) throw new Error("Writer or proposal changed unexpectedly");
    const document = await call("restore", { session: `inspect-${phase}`, actorID: `observer-${phase}`, snapshot: accepted });
    if (document.blocks.find((block: any) => block.id === "large")?.blob !== "x".repeat(8_000_000)) throw new Error("Large original content was lost");
    if (phase !== "failed-save" && JSON.stringify(accepted) !== JSON.stringify(retainedSnapshot)) throw new Error("Transport failure changed accepted history");
    if (phase === "failed-save") {
      const paragraph = document.blocks.find((block: any) => block.id === "p");
      if (!paragraph?.content.map((node: any) => node.text ?? "").join("").includes("local save retry")) throw new Error("The failed-save author edit was not retained");
      retainedSnapshot = accepted;
    }
    const archives = (await readdir(root)).filter(name => !exportsSeen.has(name) && /^recovery-.*\.json$/.test(name));
    if (phase !== "offline" && !archives.length) throw new Error("This phase's visible export produced no new archive");
    const archiveProof: Record<string, unknown>[] = [];
    for (const name of archives) {
      const archive = JSON.parse(await readFile(join(root, name), "utf8"));
      if (archive.purpose !== "recoveryArchive" || archive.actorID !== actor || archive.recovery) throw new Error("Unexpected archive envelope");
      const payload = JSON.parse(Buffer.from(archive.snapshot, "base64").toString());
      if (JSON.stringify(payload) !== JSON.stringify(accepted)) throw new Error("Export omitted current accepted history or the failed-save author edit");
      const imported = await call("restore", { session: `archive-${randomUUID()}`, actorID: randomUUID(), snapshot: payload });
      if (imported.blocks.find((block: any) => block.id === "large")?.blob !== "x".repeat(8_000_000)) throw new Error("Fresh-actor archive restore lost original content");
      const archived = await readFile(join(root, name));
      await reserve(); await writeFile(join(evidence, `${phase}-${name}`), archived);
      archiveProof.push({ name, bytes: archived.byteLength, sha256: createHash("sha256").update(archived).digest("hex"), freshActorRestore: true });
      exportsSeen.add(name);
    }
    const serverAfter = await readFile(join(directory, "relay", `${room}.json`), "utf8");
    if (serverAfter !== serverBefore) throw new Error("Relay acknowledged oversized history");
    await writeFile(join(evidence, `accepted-server-after-${phase}.json`), serverAfter);
    const observedRetry = retryAttempts.filter(attempt => attempt.phase === phase);
    if (["prepare", "retry"].includes(phase) && (observedRetry.length !== 1 || !observedRetry[0].completion))
      throw new Error("Visible retry lacked a newly completed authenticated 413 POST");
    if (["offline", "failed-save"].includes(phase) && posts.some(post => post.phase === phase)) throw new Error("Offline phase sent a relay POST");
    phases.push({ phase, actorPreserved: true, pendingProposal: false, fullBlobRetained: true, exports: archiveProof,
      acceptedChanges: accepted.changes.length, serverHistoryUnchanged: true, retryAttempts: observedRetry });
  }
  async function phase(name: string) {
    await reserve();
    currentPhase = name;
    const resultBundle = join(evidence, `${name}-${randomUUID()}.xcresult`);
    const output = await run([...buildArguments, "-only-testing:EditorLab-UITests/TransportCapacityUiTests/testCapacityProcessPhase",
      "-resultBundlePath", resultBundle, "test-without-building"], { ...process.env,
      TEST_RUNNER_BLOCK_EDITOR_CAPACITY_PHASE: name, TEST_RUNNER_BLOCK_EDITOR_CAPACITY_ENDPOINT: endpoint,
      TEST_RUNNER_BLOCK_EDITOR_CAPACITY_DRAFT_ID: draftID,
      TEST_RUNNER_BLOCK_EDITOR_CAPACITY_TOKEN: token, TEST_RUNNER_BLOCK_EDITOR_CAPACITY_CONTROL: control!.url.toString() }, join(evidence, `${name}.txt`));
    if (!/Executed 1 test/.test(output) || !/Test Case.*testCapacityProcessPhase.*passed/.test(output)
      || /\bskipped\b/.test(output) || !/\*\* TEST(?: EXECUTE)? SUCCEEDED \*\*/.test(output))
      throw new Error(`Capacity phase ${name} did not execute successfully`);
    await inspect(name);
  }
  await phase("prepare");
  await relay.close(); relay = undefined;
  await phase("offline");
  await phase("failed-save");
  relay = await startRelay({ ...options, port });
  await phase("retry");
} finally {
  try { await restoreStorage(); } finally {
    control?.stop(); proxy?.stop(); bridge.close(); if (relay) await relay.close();
    await writeFile(join(evidence, "phases.json"), JSON.stringify({ simulator, derivedData, phases,
      qualification, posts, retryAttempts,
      bridgeSHA256: await hash(executable),
      harnessSHA256: await hash("scripts/test-apple-capacity.ts"),
      uiTestSHA256: await hash("Examples/AppleDemo/UITests/TransportCapacityUiTests.swift"),
      exampleAppSHA256: await hash("Examples/AppleDemo/EditorLabApp.swift"),
      draftFile, note: "OS 27 reference workflow; no minimum-runtime or other Apple-family acceptance implied" }, null, 2));
    await rm(directory, { recursive: true, force: true });
  }
}
