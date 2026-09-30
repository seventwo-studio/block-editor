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
The Android emulator can reach a host loopback server through `10.0.2.2`; its native
demo adapter and device test remain to be implemented. Physical devices require a
deliberate local forwarding setup. The relay does not open a public/LAN listener.

Uncheck **Connected to local server** to edit independently. Reconnect to merge.
Browser controls include a burst of 20 edits; the CLI stress runner performs larger
repeatable scenarios. Clients poll every 500 ms, display pending changes and peers,
and retry transient errors without dropping local edits. Disconnect ignores late
responses. An already-sent request may have reached the relay; duplicate delivery
is safe on rejoin. Local edits in the interactive lab are held in memory until
acknowledged; offline client restart persistence remains a separate acceptance gate.

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
- macOS demo executable and reusable Apple demo view build; native UI interaction
  is not yet verified.
- Firefox was retried and still fails before test execution with “Could not find
  profile folder”. Android and other Apple runtime/device matrix rows remain open.

Run results are evidence for these precise scenarios, not permission to close the
full platform, editor parity, release or consumer-integration issues.
