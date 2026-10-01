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

`./script/build_and_run.sh` builds and opens the macOS demo as a native app bundle.
Use `--build-only` to stage it without launching, `--verify` for a process check,
`--debug` for LLDB, or `--logs` for runtime logs. Use
**Open local document** to create or reopen the standalone document without a
server, token, account, or network client. It saves automatically to
Application Support/BlockEditorLocalLab/local-only.json and retains author undo
history across restarts. Hosts can embed `LocalEditorDemoView(file:)` with their
own file URL. **Open collaborative lab** opens the relay configuration below.

For the collaborative lab, use
`http://127.0.0.1:4319/rooms/shared-demo` and the same token. Other Apple demo apps
can embed `LocalRelayDemoView` from `BlockEditorDemoApple`; their app manifests,
local networking permissions and real-device execution still need acceptance.

The command-line native HTTP client is also useful for mixed-runtime tests:

```sh
DEMO_TOKEN=choose-a-local-test-token swift run relay-client
```

To retain a native client's local history across process restarts, set
`DEMO_DRAFT=/path/to/draft.json`. `DEMO_OFFLINE=1` saves without exchanging changes;
`DEMO_ACTION=inspect` restores without editing, `rejoin` exchanges without adding
text, and `undo` reverses the last local action. `DEMO_TEXT` overrides the text
appended by the default `edit` action. A saved draft can reopen with the relay
stopped and without a token; reconnect requires the token again.

The Apple demo saves automatically under Application Support/BlockEditorLocalLab,
with one draft per endpoint. Restored drafts start disconnected. The host storage
adapter uses atomic snapshots and a file lock held for the whole session so two
writers cannot reuse its saved author identity. Corrupt, incompatible or
endpoint-mismatched drafts fail explicitly without being replaced. Tokens and
presence are excluded. Save failures are displayed separately from sync status.

It loads the server snapshot, disconnects, edits through the Swift engine, rejoins
and requires acknowledgement. Set `DEMO_ENDPOINT` to another room URL if needed.
Runnable Apple simulator app targets and iPhone/iPad UI test commands are in
[Examples/AppleDemo](../Examples/AppleDemo/README.md). They use the same shared
demo views and OS 26 minimums.

The Android `:demo` app includes a Compose editor, token/room inputs, pending and
participant counts, and a disconnect switch. It saves per-endpoint drafts in app-private
storage using `AtomicFile` and an exclusive writer lease. Restores start disconnected,
retain author undo history and require no token; enter the token before reconnecting.
The last endpoint is remembered, but tokens and presence are not saved. Storage
failures are displayed while the edited document remains in memory. Build the native libraries with
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
Android storage and real process-restart recovery are tested. Apple storage/process
recovery is also tested, including native iPhone/iPad UI relaunch. Other Apple
platforms' UI relaunch and real input-method/accessibility acceptance remain open.

### macOS window verification (2026-09-30)

The native demo at commit `3295c8c` was exercised through Computer Use in an
isolated room on a loopback relay. Its actual text view accepted Unicode plain-text
paste (`café 👩🏽‍💻`), keyboard undo/redo, and selected-range replacement. After
disconnecting, local typing and a separate CLI replica's append survived reconnect
with zero unacknowledged changes. Keyboard undo removed a local character while
preserving the remote append. After quitting the app and stopping the relay,
reopening the same room with an empty token restored the document and undo/redo
availability in disconnected mode.

This verifies those macOS interactions only. Synthetic Unicode `typeText` initially
produced incomplete text; Unicode paste succeeded. Real input-method composition,
VoiceOver navigation, rich paste sanitization, and the other native platforms'
window interactions remain acceptance work. Accessibility-tree visibility alone
does not establish screen-reader usability.

The standalone chooser was also exercised in the macOS window: create a new blank
document, paste Unicode content, quit, reopen, and undo the restored edit. No relay
address or token was entered. Standalone storage tests verify that opening an
existing relay draft through the local API fails without overwriting it.

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
swift test --filter generatedOfflineTextAndFormattingConverge
bun run test:relay
bun run test:relay:browser --project chromium --project webkit
# Starts and removes its own isolated local relay; use installed Xcode destinations.
bun run test:relay:apple \
  "platform=iOS Simulator,name=iPhone 18 Pro" \
  "platform=iOS Simulator,name=iPad Pro 13-inch (M5)"
gradle -p android :editor:connectedDebugAndroidTest :demo:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.relayUrl=http://10.0.2.2:4319 \
  -Pandroid.testInstrumentationRunnerArguments.relayToken=choose-a-local-test-token
# Build both demo APKs and the native relay-client first; the relay must be running.
ANDROID_SERIAL=emulator-5556 DEMO_TOKEN=choose-a-local-test-token sh scripts/test-android-restart.sh
# Builds/installs APKs using existing toolchains, starts isolated v1/v2 relays,
# and verifies recovery across real Android process termination and relay restart.
ANDROID_HOME=/path/to/android-sdk ANDROID_SERIAL=emulator-5556 \
  GRADLE_BIN=/path/to/gradle bun run test:android:recovery
DEMO_TOKEN=choose-a-local-test-token STRESS_REPLICAS=8 STRESS_ROUNDS=40 STRESS_SEED=20260930 bun run demo:stress
```

The Apple relay runner builds the native server bridge, starts an ephemeral
loopback listener with a fresh test token, and passes that configuration to Xcode
using `TEST_RUNNER_` environment variables. Each destination exercises presence,
disconnected editing, local draft save/restore, concurrent rejoin, author-specific
undo, composition receipt gaps, and authentication recovery. The runner closes the
server and removes its temporary room data after testing. Ordinary Swift test runs
skip the network case unless explicitly configured; the offline draft tests still
run. Native window and input-method acceptance is a separate check.

The Android recovery runner passes an API 35 arm64 packaged-library/input suite,
draft/archive checks and visible Compose recovery interaction. It then invokes
three separate instrumentation processes: retain/export a rejected union, force-stop
and restore/repair while the relay is stopped, force-stop again and reconnect the
repaired draft to the restarted relay. The same saved author resumes; neither
restart drops the accepted content or pending history. Restoring requires no token,
and reconnect requires the local token. Existing default-v1 process-restart
acceptance keeps its separate command. API 26, x86 runtime, installed-keyboard IME,
TalkBack and full Notion-like Android authoring remain open. The browser recovery
host still needs separate proposal persistence and visible repair/export controls.

The stress runner uses independent native Swift processes, overlapping Unicode
inserts/replacements/deletions, formatting and mark removal, block insert/move/delete,
undo/redo, a long offline period for one replica, and seeded intermittent outages
for the others. It sends only part of a reversed change batch, duplicates operations,
and later fills receipt gaps through delta synchronization. Every sixth round it
terminates and restores each client process, checking document and undo/redo state.
The final recovery flushes all changes, checks identical documents on every client
and a fresh server-snapshot observer, and requires zero missing/unacknowledged
changes in both directions. Results include the seed, elapsed time, UTF-8 document
bytes, exchange/partial-delivery/restart counts and attempted operations by kind.
An attempted edit can be a no-op, for example formatting an empty selection.
Failures include seed, round and actor so the run can be repeated. The relay test also
restarts the server and verifies incompatible protocol rejection without changing
the saved file. These checks do not establish a performance budget or complete
conflict coverage.

The Swift generated suite uses eight fixed seeds, four replicas and eighteen rounds
per seed. It covers paragraph and nested list text, emoji, combining marks, CJK,
right-to-left text and atomic references. Each local replacement has an independent
plain-text expectation; formatting preserves references and text; every action is
checked against saved-history replay. It also verifies author-specific undo/redo
after full recovery. A separate exact formatting scenario runs in Swift, Android
JNI and Chromium/WebKit WASM: a formatting packet arrives before the Unicode
insertion it references, and undo preserves the other author's insertion and marks.

The mixed-runtime browser test opens two actual WASM editors plus a native Swift
Foundation HTTP client. All edit offline, rejoin the same relay, converge, and then
verify one browser author's undo retains both other authors' edits.

## Current evidence (30 September 2026)

- Four native Swift clients, 12 rounds: convergence and server restart/rejection
  checks pass.
- Expanded relay scenarios pass with four clients: seed 42 for 12 rounds, and seeds
  1, 65537 and 20260930 for 18 rounds each. All exercise partial delivery and process
  restart, then finish with matching documents and complete acknowledgements.
- Expanded eight-client, 40-round scenario, seed 20260930: 186 exchanges, 170 partial
  exchanges and 48 process restarts converged in 28,066 ms. This workload now includes
  deletion/replacement and delta batches, so its timing is not comparable to the
  earlier append-heavy runs below and is not an accepted performance budget.
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
- The native relay and offline-draft suite passes on macOS and iPhone, iPad, tvOS
  and watchOS simulators against an isolated central server. This verifies each
  runtime's HTTP adapter, storage and merge behavior; it does not establish native
  window, keyboard, remote-control, watch-input or accessibility acceptance.
- macOS demo executable and reusable Apple demo views build. UIKit component tests
  verify marked text and selection on iPhone and iPad. visionOS builds, but its
  simulator runtime is not installed and server integration remains unverified.
- Four native UI workflows pass on both iPhone and iPad: standalone restart and
  restored undo/redo; offline collaboration, presence, acknowledgment and recovery;
  table/toggle/nested-list editing and reopen; and wrapped paragraph sizing and
  reopen. Retained rich-block screenshots were inspected in light and dark mode.
  Ten macOS and ten iPhone input tests also verify that remote insertion updates
  the selection used by formatting controls. Real IME and accessibility acceptance
  remain open.
- Native draft tests verify exclusive writer access, corrupt/mismatched file
  preservation and author-history restore. Separate Swift processes save offline,
  reopen while the relay is stopped, rejoin remote edits, and undo only local text.
- Android API 35 arm64 emulator: shared JNI fixture and two-client offline/rejoin,
  convergence, acknowledgement and author-specific undo instrumentation pass.
  Both arm64 and x86_64 native libraries build; x86_64 execution and API 26 device
  acceptance remain open. Compose selection/typing and Android InputConnection
  composition tests pass; third-party keyboard, paste and accessibility acceptance
  remain open.
- Android separate instrumentation processes save an offline draft, terminate,
  reopen without a token, merge an intervening native edit and undo only local text.
  Additional instrumentation rejects concurrent writers and preserves malformed,
  incompatible and endpoint-mismatched drafts. The restart script requires
  `ANDROID_HOME`; override `DEMO_URL` and `ANDROID_RELAY_URL` for a non-default port.
- Swift tests pass, including eight generated convergence scenarios, exact concurrent
  formatting/undo expectations, and incremental-edit equivalence with complete
  history replay after each action. An earlier eight-client stress run converged
  in 111,040 ms while other builds ran; no latency improvement is claimed.
- Firefox was retried and still fails before test execution with “Could not find
  profile folder”. Other Apple runtime/device matrix rows remain open.

Run results are evidence for these precise scenarios, not permission to close the
full platform, editor parity, release or consumer-integration issues.

The Apple reference also exposes explicit v2 recovery controls. Accepted content
stays selectable while typing and undo wait; a rejected union is persisted
separately, and the author can choose a supported wrap repair, export the accepted
and pending histories, or retry synchronization. Host draft version 2 reads legacy
version 1 without resetting the writer. Recovery archives reopen with a fresh actor
and cannot overwrite an existing file. The iPhone/iPad OS 27 app suite covers real
HTTP 409, export, offline restart, on-screen repair and repaired resubmission.
See [the recovery contract](merge-recovery.md) for the storage boundary and remaining
Android/browser and Apple-family interaction acceptance. The default-v1 reference
and standalone network-free workflows remain available.
