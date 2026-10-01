# Reference integration acceptance

[ST-48](https://linear.app/seventwo/issue/ST-48/verify-local-and-collaborative-reference-integrations)
assembles reference, runtime and private-package evidence for approved consumer
delivery. Keep the existing offline save/reopen/undo, simultaneous editing,
presence and seeded stress evidence. Complete the remaining gates with their
owners; a merged change does not establish installation or platform acceptance.

## Gates and evidence owners

| Gate | Owner | Required evidence |
| --- | --- | --- |
| Runtime compatibility and budgets | [ST-39](https://linear.app/seventwo/issue/ST-39/build-and-verify-the-swift-engine-across-runtimes), ST-93, ST-94 | Exact shared fixture inputs/results on native Swift, API 26 x86_64, API 35 x86_64/ARM64, and Chromium/WebKit/Firefox WASM; accepted size/startup/execution budgets |
| All-platform local relay | [ST-105](https://linear.app/seventwo/issue/ST-105/complete-the-local-relay-demonstration-across-every-platform) | Actual reference surfaces on each Apple family, Android and all three browser engines; offline edits/rejoin, presence, local undo, client process restart, server restart, v2 recovery and the separate 8 MB transport limit |
| Reviewed private delivery | [ST-34](https://linear.app/seventwo/issue/ST-34/prepare-internal-package-delivery) | Linked reviewed recovery decision, treatment of exposed publication, verified private visibility/access and unchanged $0 cap with Stop usage |
| Clean package assembly | [ST-106](https://linear.app/seventwo/issue/ST-106/verify-private-editor-packages-in-clean-consumer-hosts) | Approved versioned Swift, Kotlin/AAR and TypeScript/WASM delivery contracts, fresh consumer installs, actual initialization and smoke results |

These are the existing ST-48 prerequisites. Private-delivery recovery can proceed
independently of relay work; final installation acceptance also consumes runtime
verification. See [runtime CI](runtime-ci.md), [the relay contract](local-sync-lab.md)
and [merge recovery](merge-recovery.md) for repeatable owner workflows.

## Baseline reviewed on 1 October 2026

Source inspection used default revision
`e7d616a0262eac4c368fdcf83f18890b5a83e5ac`.
Its [default-branch CI run](https://github.com/seventwo-studio/block-editor/actions/runs/36855114396)
completed successfully, including native Swift, the three Android matrix entries,
three-browser WASM and runtime parity. This establishes that revision's fixture
and measurement-smoke execution. Numeric budget acceptance remains ST-94 work.

Retained reference evidence is scoped as follows. The linked issues hold the
original source revisions, commands and results; later evidence must identify its
own installed artifacts and source.

| Reference | Retained evidence | Remaining acceptance |
| --- | --- | --- |
| Native local reference | Save/reopen with restored author undo; standalone macOS window, iPhone/iPad UI and independent Swift process checks | Wider platform/input acceptance stays with its platform owners |
| Chromium/WebKit relay reference | Two WASM editors plus native Swift client converge after offline edits; undo preserves remote text; persisted draft reload/tab-close recovery with blocked relay requests | Full browser process restart, all three engines, v2 host recovery and transport-capacity workflow |
| macOS relay reference | Actual window disconnect/edit/rejoin, zero unacknowledged changes, remote-preserving keyboard undo and token-free offline quit/reopen at `3295c8c` | Remaining actual v2/capacity and input/accessibility checks |
| iPhone/iPad relay reference | Native UI offline/rejoin/presence/history; OS 27 visible v2 rejection/export/repair/resubmission and offline restart at `7cfa52212b2b79f33fb1c2361395adba2b03122c` | Other required runtime/input rows and separate transport-capacity workflow |
| watchOS/tvOS | Runtime HTTP adapter, draft storage and merge tests | Actual platform text-entry/remote interaction and process-restart/recovery matrix |
| visionOS | Compilation | Runtime absent in retained local evidence; actual reference execution remains open |
| Android | API 35 ARM64 instrumentation and v1 process restart; three independent instrumentation processes retain/export, offline restore/repair and resubmit after relay restart at `275be9c6609d7da7986a8fb18c190fc74deab85f` | Remaining runtime/input/presence matrix and transport-capacity workflow |
| Seeded stress | Duplicate/reordered partial batches, offline rejoin, client/server restart, convergence and author-local undo | Broader host interaction is tracked separately; stress timing is not an accepted budget |

Firefox compatibility succeeds in the linked hosted CI. Earlier local Firefox
launch failures remain diagnostic history and cannot substitute for three-browser
reference relay acceptance. Reload, activity recreation and tab reopen do not
prove termination and restart of a client process. Relay-disabled draft recovery
does not establish cold-start offline web asset availability: the browser shell
and WASM are still served locally.

## Package assembly review

Record the selected private delivery contract for every family before an install
can pass. Selection itself does not authorize publication, deletion, token scope
changes, paid usage or a consumer repository edit.

| Family | Contract to record | Assembly to verify in the installed consumer |
| --- | --- | --- |
| Swift | Approved private repository/source package or binary route, exact immutable revision/version, authorized read method, dependency resolution and protocol compatibility | `BlockEditorCore` and `BlockEditorApple` initialize on supported OS 26 targets; approved binaries contain the declared platforms/architectures; local snapshot/history and optional exchange work |
| Kotlin/AAR | Approved private Maven/other delivery route, exact coordinates/version, artifact/POM integrity, transitive dependencies, read method and supported JNI architectures | Release AAR has Kotlin API and, for each promised ABI, `libBlockEditorJNI.so`, `libBlockEditorBridge.so` and `libc++_shared.so`; load through the installed artifact and run JNI/session smoke on API 26 and required reference runtimes |
| TypeScript/WASM | Exact wrapper identity/version/registry integrity, approved private WASM route, WASM SHA-256, engine revision, protocol/baseline compatibility and host asset loading | All declared exports/CSS resolve; host-provided bytes initialize `SwiftEditorRuntime`, the React adapter mounts, and the same wrapper/module pair runs session smoke in Chromium, WebKit and Firefox |

At the inspected revision, `package.json` and `scripts/check-package.mjs`
intentionally exclude `.wasm`. The wrapper needs separately supplied module bytes
or a compiled module. Its runtime checks ABI exports and memory; that check alone
does not establish wrapper/engine protocol compatibility. `Package.swift` exports
source products with OS 26 minimums. The Android library targets API 26 and defaults
to ARM64/x86_64, but has no Maven publication coordinates. A single-ABI CI test AAR
cannot establish a promised dual-ABI release. No accepted private delivery identity
exists for all three families in this evidence snapshot.

The old npm `0.1.0` local tarball check establishes exports and legacy React smoke
only. It does not initialize the Swift WASM engine or deliver native packages.
Never substitute a tarball, editor checkout, workspace symlink, local Maven cache,
Swift local path dependency or locally built WASM for accepted private installation.

## Clean consumer procedure

1. Link the reviewed ST-34 decision and each family's delivery contract. Record
   approved consumer/read principal, exact package versions/revisions, source SHA,
   artifact integrity, protocol versions and compatible wrapper/engine pairing.
   Keep credentials out of reports. Do not invent a native delivery path from the
   npm proposal or grant unnamed consumers access.
2. Use disposable approved consumer hosts and fresh package/dependency caches.
   Record the exact install commands, registry/source resolution, lockfiles and CI
   job. Require immutable pins and fail on unexpected source or integrity. The
   consumer must resolve without the editor checkout, local artifacts or public
   fallback. Consumer builds may resolve approved Swift source normally; they
   must not depend on a developer's cached checkout.
3. Verify private visibility and allowed access, then execute the reviewed denial
   check. The proposed npm check uses the same approved Foliostrate principal
   after a separately approved temporary removal of its Read grant, a fresh own
   job token and empty package store. Require registry 401/403/404 for the exact
   package identity/tarball; a generic install/build failure does not prove denial.
   Restore exactly Read and repeat the successful clean install. Do not create
   another principal or grant. Record access metadata and results without tokens
   or auth configuration; denial procedures for native routes remain unselected.
4. Inspect the installed assembly, initialize actual native/JNI/WASM engines, and
   execute the shared compatibility fixtures. Record input hashes and complete
   responses; explicit unsupported protocol, baseline and migration failures must
   preserve accepted state. Consume matching runtime evidence for platform work
   rather than rebuilding every runtime just to repeat the existing matrix.
5. Through an installed reference host, save/reopen/undo with relay networking
   disabled; exchange simultaneous edits with a peer, check presence, disconnect,
   edit offline, rejoin and undo only the local author. Presence must not change
   persisted bytes. Use matching ST-105 evidence for full platform coverage; retain
   accepted snapshots and rejected proposals separately during recovery/restart.
6. Link fresh consumer CI and results to ST-106 and the ST-48 assembly record.
   Record any skipped/failed row explicitly. Wait for all prerequisite acceptance
   before completing ST-48; package merge/publication/installation and app adoption
   remain separate states.

## Evidence handoff

Each result needs the source SHA and, for dirty development evidence, patch hash;
engine/JNI/WASM artifact SHA-256 and their source provenance; wrapper/package
version and registry integrity; fixture input hashes; OS/API, architecture,
browser version/executable and toolchain versions; exact command and scenario;
result/CI artifact links; and remaining gaps. Hashing a binary alone cannot identify
its source revision. Newer invalid evidence must not fall back silently to an
older passing report.

For process/recovery scenarios also record distinct process IDs, client and server
restart phases, accepted content/history/receipts before and after, separately
retained pending proposal, repair/export/retry results, missing/unacknowledged
changes and presence expiration/document invariance. Tab/activity recreation is
reported separately. An 8 MB exchange rejection must preserve all unacknowledged
input and expose an actionable retention/export/retry path without false receipts.

Hosts continue to own storage, authorization, authentication, transport and assets.
Therein, Foliostrate and Parqeet adoption belongs to their app work. The unnamed
local-only concept keeps its separate scope decision. Naming those consumers
does not authorize unrelated product changes or enable collaboration by default.
