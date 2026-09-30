# Local cross-platform sync lab

The lab runs a centralized **local-only** HTTP relay backed by the real Swift
engine. It is a test adapter, not a production collaboration service. The engine
still works without it. The relay binds only to `127.0.0.1`, requires a demo token,
does not enable CORS, and stores snapshots in `.local-demo` by default. Keep demo
documents out of production data. No external service or paid resource is used.

## Run

Use separate terminals from the repository root:

```sh
DEMO_TOKEN=choose-a-local-test-token bun run demo:relay
bun run demo:dev
```

Build WASM using the toolchain instructions in [shared-swift-editor.md](shared-swift-editor.md)
before opening `http://127.0.0.1:5173/block-editor/local.html`. Enter the same room
and token in each browser. Each opened client gets a unique writer identity.

`swift run local-editor-app` opens the macOS demo. Use
`http://127.0.0.1:4319/rooms/shared-demo` and the same token. Other Apple demo apps
can embed `LocalRelayDemoView` from `BlockEditorDemoApple`; their app manifests,
local networking permissions and real-device execution still need acceptance.

The command-line native HTTP client is also useful for mixed-runtime tests:

```sh
DEMO_TOKEN=choose-a-local-test-token swift run relay-client
```

It loads the server snapshot, disconnects, edits through the Swift engine, rejoins
and requires acknowledgement. Set `DEMO_ENDPOINT` to another room URL if needed.
The Android `:demo` app includes a Compose editor, token/room inputs, pending and
participant counts, and a disconnect switch. Build the native libraries with
`scripts/build-android.sh`, then build/install `:demo:assembleDebug` with Gradle.
The script bundles the NDK C++ runtime alongside Swift and JNI libraries.
The emulator reaches the host loopback server through `10.0.2.2`; cleartext HTTP
is enabled only in the debug manifest. Physical devices require a
deliberate local forwarding setup. The relay does not open a public/LAN listener.

Uncheck **Connected to local server** to edit independently. Reconnect to merge.
Browser controls include a burst of 20 edits; the CLI stress runner performs larger
repeatable scenarios. Clients poll every 500 ms, display pending changes and peers,
and retry transient errors without dropping local edits. Disconnect ignores late
responses. An already-sent request may have reached the relay; duplicate delivery
is safe on rejoin.

The browser lab saves each document change and its author undo history in IndexedDB.
Wait for **Saved locally** before closing the tab. Reload resumes that tab's draft;
after closing it, choose a **Saved local draft** for the room in a new tab. Restored
drafts open disconnected and can be edited without contacting the relay. Re-enter
the demo token before reconnecting; tokens are not stored. A browser Web Lock keeps
two tabs from resuming the same writer concurrently. Storage errors are visible and
never reported as successful saves. Browser data clearing removes these drafts.
The application shell and WASM still need to be served locally when opening the
page; this is document recovery with the relay unavailable, not offline web hosting.
Apple and Android offline client restart persistence remains an acceptance gate.

## Wire contract

- `GET /rooms/<id>` returns a versioned Swift session snapshot, creating the demo
  room if absent. Room IDs contain 1–80 ASCII letters, digits, hyphens or underscores.
- `POST /rooms/<id>` receives `{ actorID, batch, state, presence }`. `batch` is
  `ChangeBatch`; `state` is the client's exact receipt set. The response is
  `{ batch, state, presence, exchanges }`, where `batch` contains changes the client
  has not acknowledged and `state` is the server receipt set.
- Every request supplies `X-Local-Token`. This token gates a trusted local demo,
  not per-user authorization. The host/service must implement real authorization
  for a production integration.
- A single native Swift bridge serializes merge operations. The relay serializes
  complete receive/save/ack transactions, persists via temporary file plus rename,
  then acknowledges. A restart restores the last successfully persisted snapshot.
- Presence is held separately in memory, expires after five seconds without refresh,
  and is omitted from saved document state. The current demo reports participants;
  selection/caret presence rendering remains open.
- Request bodies are capped at 8 MB. Engine protocol/version/baseline errors are
  explicit. This is not a streaming or compacted transport for large histories.

## Verification commands

```sh
bun run typecheck:relay
bun run test:relay
bun run test:relay:browser --project chromium --project webkit
gradle -p android :editor:connectedDebugAndroidTest :demo:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.relayUrl=http://10.0.2.2:4319 \
  -Pandroid.testInstrumentationRunnerArguments.relayToken=choose-a-local-test-token
DEMO_TOKEN=choose-a-local-test-token STRESS_REPLICAS=8 STRESS_ROUNDS=40 STRESS_SEED=20260930 bun run demo:stress
```

The stress runner uses independent native Swift processes, Unicode text edits,
formatting, block insert/move/delete, undo/redo, a long offline period for one
replica, seeded intermittent disconnections for the others, and duplicated/reversed
operation delivery. It asserts all clients and a newly restored observer have the
same document, and reports elapsed time and exchange counts. The relay test also
restarts the server and verifies incompatible protocol rejection without changing
the saved file. These checks do not establish a performance budget or complete
conflict coverage.

The mixed-runtime browser test opens two actual WASM editors plus a native Swift
Foundation HTTP client. All edit offline, rejoin the same relay, converge, and then
verify one browser author's undo retains both other authors' edits.

## Current evidence (30 September 2026)

- Four native Swift clients, 12 rounds: convergence and server restart/rejection
  checks pass.
- Eight native Swift clients, 40 rounds, seed 20260930: 165 exchanges converged in
  107,553 ms on the development host. This exposes significant replay/transport
  overhead to improve; it is not an accepted latency target.
- Chromium and WebKit: mixed WASM/native HTTP collaboration and undo tests pass.
- Browser drafts survive reload with the relay blocked, preserve local undo/redo,
  and merge remote edits after reconnect. Closing a tab and selecting its saved
  draft retains author history; a duplicate tab cannot acquire the writer lock.
- Presence lease expiry, stale revisions, explicit departure and relay restart
  preserve identical saved document bytes, including when cursor/selection data
  is exchanged. Browser tests verify visible transport errors, recovery and local
  presence cleanup on disconnect. Android instrumentation verifies peer counts
  are cleared on disconnect.
- macOS demo executable and reusable Apple demo view build; native UI interaction
  is not yet verified.
- Android API 35 arm64 emulator: shared JNI fixture and two-client offline/rejoin,
  convergence, acknowledgement and author-specific undo instrumentation pass.
  Both arm64 and x86_64 native libraries build; x86_64 execution and API 26 device
  acceptance remain open. Compose input and accessibility interaction are unverified.
- Twenty Swift tests pass, including incremental-edit equivalence with complete
  history replay after each action. An additional eight-client stress run converged
  in 111,040 ms while other builds ran; no latency improvement is claimed.
- Firefox was retried and still fails before test execution with “Could not find
  profile folder”. Other Apple runtime/device matrix rows remain open.

Run results are evidence for these precise scenarios, not permission to close the
full platform, editor parity, release or consumer-integration issues.
