# Shared Swift editor

## Accepted direction

One platform-independent Swift engine serves Therein, Foliostrate, Parqeet and an
unnamed local-only document editor. Deliver the engine, native interfaces, then the
React/WASM replacement. Naming a consumer neither enables collaboration nor changes
that app's product scope. Parqeet's current scope still excludes collaborative
document management. Foliostrate remains visual-only for help articles and FAQs.

The engine owns document data, validation, editing, formatting, Markdown conversion
and merge semantics. Hosts own storage, transport, authentication, authorization,
media, autosave and publication. UI restrictions are not authorization. Local hosts
need no account, network, server or synchronization configuration. Collaborative
hosts use the same session with optional change exchange and ephemeral presence.

Concurrent edits within text and author-specific undo supersede the earlier
block-level-only collaboration proposal. Existing content, IDs, formatting,
references and nesting must survive migration. Apple OS 26 and Android API 26 are
the minimum targets. Public distribution and a production collaboration backend
are outside this work. The recorded package-visibility recovery blocker remains.

## Implemented foundation

The [local sync lab](local-sync-lab.md) extends the reference work with a centralized
loopback server, native and browser clients, and repeatable offline/rejoin stress
tests. Its platform evidence is tracked separately from editor feature parity.

`BlockEditorCore` provides `Document`, `Block`, `EditorSession`, `TextAddress`,
`ChangeBatch`, `SyncState`, `Presence` and Markdown conversion. A session is confined
to one executor. Keep actor IDs unique per writer; resuming a saved actor requires
exclusive ownership. A fresh actor intentionally starts without the previous
writer's local undo history. Document IDs and actor IDs are independent.

```swift
import BlockEditorCore

let document = try Document(blocks: [.paragraph(id: "intro", text: "Hello")])
let session = try EditorSession(documentID: "note", actorID: "writer-1", document: document)
session.onChange = { document, change in /* update UI / schedule host persistence */ }
try session.replaceText(at: TextAddress("intro"), range: 5..<5, with: " world")
try session.undo()
let saved = try session.save()
let reopened = try EditorSession.restore(saved, actorID: "writer-1")
```

Save returns a versioned session snapshot, including local undo/redo history. Bare
document JSON is available separately from `Document.json()`. Presence is excluded
from both. Host storage must atomically persist the returned bytes. The engine
does not access the filesystem or network. Reference executables demonstrate host
filesystem persistence and an in-memory exchange between disconnected replicas.

Text uses Unicode scalar atoms with stable IDs and UTF-16 edit ranges. Ranges that
split a scalar or structured reference fail. A plain-input edit inside a reference
converts the affected reference label to ordinary text. Unaffected references and
fields survive. Formatting targets surviving atom IDs. A Lamport counter plus
ASCII actor ordering resolves concurrent assignments deterministically. Insertion
anchors survive deletion and undo; top-level block movement uses placement records.
Concurrent deletion wins over movement. Undo toggles only the local author's
transaction; unrelated remote transactions remain active. Undoing a block insertion
hides that block, including subsequent edits inside it, until redo restores it.

Replicas exchange `changes(since: peer.syncState)` and atomically `receive` batches.
Exact receipt IDs avoid falsely acknowledging gaps in out-of-order delivery.
Duplicate changes are harmless; conflicting reuse of an ID, another baseline or
document ID, and unsupported protocol versions fail explicitly. Authentication and
binding an actor to a permitted author belong to the receiving host/service.
Presence revisions, expiration, disconnect cleanup and authorization are host-owned.
The current receipt set and operation log have no compaction protocol.

### Stable positions and browser composition

`EditorSession.position(at:offset:affinity:)` captures a UTF-16 scalar boundary as
a `TextPosition`; `offset(of:)` resolves it after remote edits. The position includes
its document ID, field address and an atom anchor. `before` follows the next atom
(or document-field end), while `after` follows the previous atom (or field start).
Deleted and undone atoms remain usable anchors. Display selections inside reference
labels retain an interior offset without changing reference identity. Edit ranges
still treat those references atomically. Positions are ephemeral and are not added
to saved document state; hosts may exchange them through their presence adapter.
Missing causal anchors and deleted blocks fail explicitly, allowing the host to
retry after synchronization or move focus. No history compaction is implemented.

The TypeScript session exposes `position`/`resolvePosition`; Kotlin exposes the same
bridge operations with `PositionAffinity`. The Swift React inline and code/math
textarea adapters capture positions before receive and restore forward/backward
selections after rendering, including several receives before one React commit.
They defer remote application during IME composition, commit the local composition
first, then drain remote
batches. Queued batches are excluded from receipt state. Holds can nest and release
idempotently; invalid queued batches report errors while valid batches still drain.
The queue is bounded to 64 batches/64 MB and asks the transport to retry on overflow.
Hosts must release holds or close the session when an input adapter is removed.

Code/math textareas retain the browser composition buffer until committing the
local edit and use session undo/redo for keyboard history. Native adapter behavior
and remaining platform interaction checks are described below.
Chromium IME protocol input covers inline and textarea adapters;
Chromium/WebKit selection checks and inline composition-event tests provide
additional coverage. WebKit system IME, Firefox and physical keyboard/input-method
matrices remain unverified.

The Swift session also exposes `deferRemoteChanges()` and a read-only
`onWillReceive` preparation callback. The callback runs only after a batch validates;
reentrant edits during preparation fail explicitly. Nested holds preserve receipt
and saved-state gaps until release, cap pending input at 64 batches/64 MB, and drain
valid messages even when another queued message fails.

The macOS reference uses an AppKit text view, and iOS/iPadOS/visionOS use a UIKit
text view, through SwiftUI representables that observe marked-text composition.
Their coordinators capture selection before remote application, commit local
composition first, map positions after merging, and release holds on disposal.
Code/math fields use the same input path. Both bridges share attributed-text
rendering that combines code, bold and italic marks. UIKit uses plain-text paste;
host-controlled assets remain separate.

Core and Apple coordinator tests cover the state transitions and rich-reference
preservation. UIKit component tests on iPhone and iPad simulators also exercise
marked text, remote delivery, typing, selection and undo. The visionOS library
builds, but no visionOS runtime is installed for execution. Actual window, keyboard
and input-method, paste and accessibility acceptance remains required, including
macOS interaction. watchOS/tvOS text fields buffer their platform text-entry
interaction, commit the draft when entry ends, then release queued remote changes.
Their state-transition tests pass on both simulators; actual keyboard, dictation
and remote-control interaction remains unverified.

Input adapters detach callbacks on disposal and reject late input events, so an
old text view cannot overwrite a document after its composition hold is released.
Replacing the Apple `EditorModel` recreates its editor controls rather than retaining
coordinators attached to the previous session. UIKit and Android regression tests
exercise late callbacks after disposal.

The Android Compose adapter uses `TextFieldValue` to retain selection and IME
composition. Root text, code and math fields defer remote changes until composition
commits, resolve stable selection anchors after receive, and release pending changes
when disposed. Kotlin session holds have the same 64-batch/64-MB limit and receipt
semantics as the browser wrapper. Tests exercise Android's `InputConnection` on an
API 35 arm64 emulator, alongside rendered selection/typing and controller checks
for reference preservation, rejected delivery, nested holds and disposal. This does
not establish API 26, x86_64, third-party keyboard, accessibility, or rich attributed
text acceptance.

Nested fields use stable IDs, for example `items/<item-id>/content` and
`children/<child-id>/content`. Structural insert/move/delete currently operate at
the document root. Unknown block fields are retained. Validation checks known
shapes; it is not a substitute for host schema and resource-policy enforcement.

`BlockEditorABI` provides a serialized JSON boundary shared by JNI and WASM. Call
the ABI on one executor and free both request and returned response allocations.
Kotlin serializes native calls; each WASM instance owns its bridge. Browser hosts
supply module bytes or a compiled module to asynchronous initialization. React
shows loading and retryable failures. The runtime creates no network transport,
filesystem preopens or implicit image fetches.

## Migration

Document JSON remains the existing block array. Collaborative state is a separate,
experimental version-1 protocol, incompatible with legacy TypeScript block
operations. Never send both protocols to a live session. Keep original archives.

1. Stop legacy writers at a coordinated cutover and retain their operation archive.
2. Run `bun scripts/migrate-legacy-crdt.ts old-operations.json new-document.json`.
   It validates the archive and refuses existing output or ambiguous later clocks.
3. Compare the materialized document, including IDs, references and nested content,
   with the legacy host's saved document. Resolve any discrepancy before adoption.
4. Use `LegacyMigration` or create a session from that reviewed document with a new
   collaboration document ID. Distribute its exact baseline to every replica.
5. Keep the original archive for rollback. Legacy undo/operation history is not
   translated into character-level undo history.

Markdown is a content projection matching the existing limited dialect; it cannot
preserve all IDs, marks, assets or custom metadata. Use JSON for lossless storage.

## Toolchains and verification

Use Swift **6.4.0** and matching official SDKs from
[Swift downloads](https://www.swift.org/install/). The open-source toolchain is
required for cross-compilation; Xcode's compiler and a similarly numbered SDK are
not interchangeable. The verified WASM SDK archive SHA-256 is
`f07b7be3c586d92d7a07051fc6d303b87ebea67eadc40640ba59d5a8b79aa86d`.
Android uses the Swift 6.4.0 Android SDK, **NDK r30**, Java 17, compile SDK 35,
AGP 8.10.1 and Kotlin 2.1.21. Install toolchains outside this repository; supply
`SWIFT_BIN` and `ANDROID_NDK_HOME`. Scripts do not install or change system tools.

```sh
swift test
swift run local-editor /tmp/local-document.json
swift run collaborative-editor
SWIFT_BIN=/path/to/swift bun run build:wasm
SWIFT_BIN=/path/to/swift ANDROID_NDK_HOME=/path/to/android-ndk-r30 bun run build:android
bun run typecheck
bun run demo:typecheck
bun run test
bun run test:wasm
bun run test:browser
bun run check:package
```

`build:wasm` accepts additional Swift arguments, e.g. `--swift-sdks-path /path/to/sdks`.
Start `bun run demo:dev` and open `/block-editor/swift.html` after building WASM.
The reference has two independent sessions, manual/automatic change exchange,
disconnect/reconnect, presence, save and reopen. It is a development entry, not a
published deployment. Presence demonstrates editing activity, not remote caret UI.

Android includes the reusable `:editor` library and a local relay `:demo` app. After generating both JNI
architectures, a host with Android SDK 35 and Gradle 8.11.1 can run
`gradle -p android :editor:assembleDebug :editor:connectedDebugAndroidTest` with a
connected API-26-or-later device. No Gradle wrapper binary is committed yet.
`tests/BlockEditorCoreTests/Fixtures/bridge.json` is shared by Swift tests, actual
browser WASM tests and the Android instrumentation test. See
[the local sync lab](local-sync-lab.md) for Android demo and relay test commands.

## Document compatibility corpus

`tests/BlockEditorCoreTests/Fixtures/documents.json` provides seven accepted and
24 rejected document cases, exercised by native Swift, browser WASM and Android
JNI. It covers every existing block and inline type, marks, references, nesting,
omitted defaults, host metadata, unknown block extensions and invalid known shapes.
Accepted content is compared field-for-field after save/restore; native tests also
exercise edits and undo. These are synthetic regression fixtures, not a claim that
every existing consumer archive or every URL accepted by the old schema was tested.

Root block IDs must be unique. Nested list items, toggle children, table rows and
cells need unique IDs within their containing array. Different containers can
reuse IDs because editing addresses contain the complete stable path. Arbitrary
metadata fields named `id` are retained without editor identity restrictions.
The legacy schema allowed duplicate sibling IDs; migration rejects that ambiguity
explicitly instead of choosing a child or silently rewriting IDs.

`bun test src/compatibility.test.ts` checks the fixture against the legacy schema
and runs the legacy-operation cutover script on each supported valid case. It
verifies source preservation, refusal to overwrite a destination, and rejection
of ambiguous nonzero operation clocks. Archive the original operation payload and
start a new collaboration document ID; legacy operations cannot be mixed into the
Swift protocol. Unknown future block types are retained by Swift but are outside
the legacy operation script's accepted schema. Existing document size and nesting
limits still apply.

## Evidence and remaining acceptance

This is an **experimental foundation**, not completion of the approved plan.
Local verification through 30 September 2026 established:

- 30 Swift tests passed (including eight cases in the generated collaboration test),
  covering document migration, scoped nested identities,
  shared fixtures, Unicode boundaries, concurrent
  edits/formatting, all permutations of a small delivery set, duplicate delivery,
  local history across restore, structural conflicts and remote-preserving undo.
- Both reference executables ran successfully, including filesystem save/reopen.
- Swift core plus Apple view library compiled for macOS, iOS, tvOS, watchOS and
  visionOS. This is build evidence, not interaction or accessibility acceptance.
- Android arm64 and x86_64 Swift/JNI shared libraries built for API 26; Kotlin/AAR,
  demo and test APK compilation passed. API 35 arm64 emulator instrumentation
  passed the shared JNI fixture and two-client offline relay recovery/undo test.
  Ten editor instrumentation tests also pass, including rendered Compose input and
  an Android input-connection composition with a concurrent remote edit.
  The build script includes the required NDK C++ runtime. API 26 and x86_64 runtime
  interaction acceptance remain open.
- Actual WASM and React reference tests passed in Chromium and WebKit. Firefox
  could not launch its profile in this environment, including a retry with Node
  and a temporary profile path; Firefox behavior remains unverified.
- Offline file reopen passes in Chromium. In WebKit automation `File.text()`
  returns `NotReadableError`, including a byte-backed upload, so that additional
  test is explicitly deferred. WebKit session snapshot restore passes through the
  engine API; offline file reopening and native file-picker interaction remain open.
- Existing TypeScript tests and type checks passed. The existing React production
  entrypoint remains unchanged; `./swift` and `./swift/react` are opt-in references.

Open acceptance work remains independently tracked in ST-39 through ST-48:

- Full nested structural operations, Apple selection mapping across remote edits,
  wider convergence coverage and conflict-aware resource limits. Current
  document size/shape rejection can prevent an over-limit union from merging;
  hosts must not treat this prototype as an unbounded collaboration service.
- Log/receipt compaction, performance budgets and artifact-size reduction. The
  current release WASM is about 58 MB. Local edits apply incrementally; incoming
  changes and undo still replay the operation log.
- Full native authoring/rendering, rich selection and IME handling, paste policies,
  accessibility and actual platform interaction. Apple toolbar formatting exists;
  platform-attributed text formatting is not yet fully reconciled into operations.
  Android is a basic Compose reference. Rich content is retained even where the
  reference displays a placeholder instead of an authoring control.
- Complete React behavior migration: shortcuts, structured paste, splitting,
  selection, host image upload and full block controls. The reference currently
  uses plain paste and its Enter inserts a paragraph rather than splitting text.
- Further consumer archive/schema coverage, full Android runtime matrix, Firefox
  verification, installable native package acceptance and CI for the new runtimes.
- Separate consumer adoption and package visibility recovery. No consumer app was
  edited, package published, production backend added, or release blocker cleared.

Product decisions live in the [Notion record](https://app.notion.com/p/3e9bb04960098144848ed3667bfa01ea).
Engineering acceptance lives in the [Linear project](https://linear.app/seventwo/project/block-editor-985a4bda82a5).
