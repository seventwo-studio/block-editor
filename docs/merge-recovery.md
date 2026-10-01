# Explicit collaborative merge recovery

Experimental protocol v2 uses the same engine for accepted editing and recovery.
The document schema and ordinary mutation protocol remain unchanged. V1 remains
the default. This work advances ST-96; it does not enable production collaboration.

## Accepted and pending state

An individually valid offline history can conflict with another valid history:
duplicate sibling labels, excessive combined nesting or block count, or an empty
required field on a container retained for remote content. `receive` first validates
the protocol and mutations, then replays the full union. If document admission
fails, it throws `EditorError.mergeRecoveryRequired` and exposes `mergeRecovery`.

The proposal contains a reason and a canonical, sorted `ChangeBatch` of the entire
rejected union. It is transport state. `document`, `save()`, `changes()` and receipts
continue to describe only accepted history. Failed admission neither publishes a
document change nor acknowledges peer operations. Additional compatible batches
accumulate in the proposal; conflicting change identities, malformed operations,
wrong baselines and incompatible versions remain explicit protocol errors.

Ordinary authored edits and undo/redo are suspended while a proposal is pending.
This prevents reusing a counter held by an unapplied local undo. The host can still
display, save and export accepted content and separately retain pending transport
state. Presence remains ephemeral and does not participate in document recovery.

## Repair and synchronize

```swift
do { try session.receive(peerBatch) }
catch EditorError.mergeRecoveryRequired(let proposal) {
    // Persist separately from session.save(); do not acknowledge proposal.batch.
    try recoveryStore.write(JSONEncoder().encode(proposal))
}

// An explicitly chosen repair moves an original node into another valid collection.
try session.repairMerge([.move(identity: conflictingNode, collection: destination)])
// Send ordinary session.changes() through the host transport after admission.
```

`MergeRepair.move` preserves a node's original identity, label, descendants and
text. `wrap` inserts a host-chosen root block and moves the original node into its
compatible collection. New containers respect host-authored block restrictions;
the engine never invents replacement labels. `text` repairs a supported text field
using a minimal Unicode-scalar diff. Surviving atoms and marks remain intact, and
an edit splitting an atomic reference is rejected. Repair text and its source are
bounded to 100,000 UTF-16 units; at most 64 repair actions form one transaction.

The engine validates the complete repaired union before committing anything. A
failed repair leaves accepted state, receipts and the original proposal unchanged.
A successful repair admits the original histories plus one ordinary author edit,
clears the proposal and publishes the document. Its counter follows all pending
changes. Peers can replay it without a privileged recovery operation. Concurrent
repairs use the existing deterministic placement/text rules; another conflict can
produce a new explicit proposal rather than discard either repair.

Undo reverses the local author's repair while retaining other authors' changes.
If undo would recreate an invalid document, it remains a pending recovery operation
until repaired. Admitting a retained local undo reconciles the author's history
before recording the repair. Remote moves can retain an undone insertion as an
empty container; that does not restore the original author's seed text.

Swift exposes `MergeRecovery` and `MergeRepair`. Kotlin exposes `MergeRecovery`,
`MergeRecoveryException`, `MergeRepair`, and `mergeRecovery()/repairMerge()`.
TypeScript/WASM exposes `SwiftMergeRecoveryError`, `SwiftMergeRecovery`,
`SwiftMergeRepair`, and the matching session methods. Commit input composition
before requesting a repair. Storage, permissions and authorization remain host
responsibilities; repairing a merge is an edit subject to the same service checks.

## Restart, relay and capacity exhaustion

Save accepted history and the proposal as separate records. Restore the accepted
snapshot using the exclusive author identity, decode the proposal, and call
`receive(proposal.batch)`. It either applies an already repaired union or recreates
the pending recovery state. Retain input batches until receipts confirm admission.

The loopback relay returns HTTP 409 with `error: "mergeRecoveryRequired"` and the
proposal. It does not save or acknowledge rejected changes or update presence for
that exchange. The client retains the proposal, repairs it under its own author
identity and submits ordinary changes. The relay can restart from accepted room
history and admit that full repaired batch. Malformed/protocol errors return 400.
The relay's 8 MB request limit remains separate from engine capacity. An oversized
exchange returns HTTP 413 with `error: "transportCapacityExceeded"` and
`maxBytes: 8000000`. It returns no batch, receipts or presence, and does not change
accepted room history. The author retains the complete unacknowledged input and
local snapshot; retrying the same oversized request cannot advance admission.
Export both before an explicitly authorized partition/cutover or transport change.
Do not truncate the batch to get under the request limit. A relay test exports the
author's exact history, restarts both processes, restores it and verifies that
resubmission remains an explicit capacity failure with server history unchanged.
The exact boundary test admits an 8,000,000-byte valid exchange and rejects an
8,000,001-byte exchange without changing receipts or stored history.

The engine retains proposals only within 100,000 changes and 64 MB of encoded batch
data, reserving a deterministic allowance for author history and JSON envelopes so
an admitted save remains restorable. Materialized documents retain the 10,000 root block, 100 JSON nesting and
32 MB limits. If combining an additional batch exceeds retained capacity,
`recoveryCapacityExceeded` leaves the previous proposal and accepted state intact.
The caller must retain that rejected input separately; it is not acknowledged.

Before any explicit partition or epoch cutover, archive accepted history, the
pending proposal and every unacknowledged input, stop old writers and reconcile
their drafts. Never clear a pending proposal, truncate history, reinterpret versions
or discard content to make a limit pass. Automatic partitioning and compaction
are not delivered here. A bounded recoverable outcome is not unrestricted merge
convergence or an accepted performance budget.

## Apple reference recovery controls

The local Apple relay editor imports an HTTP 409 proposal through the same session
without advancing the server receipt or presence. It keeps accepted content visible
and selectable, suspends ordinary typing and undo, and offers explicit recovery
actions. The author can select an original block and place it in a new toggle,
export the complete recovery archive, or retry synchronization. The block catalogue
lists original root/toggle blocks by stable origin identity; it is not an invalid
merged-document preview. Table/list conflicts without a supported block repair
retain the export/retry path. Failed repairs leave both accepted and pending state
unchanged and display the engine error.

`LocalDraft` storage version 2 writes accepted engine snapshot and pending proposal
as separate fields in one atomic host envelope. Host storage and collaboration
protocol versions are independent. Legacy version-1 drafts reopen without resetting
their actor or content and upgrade on save. Incompatible proposal versions fail
explicitly while leaving the file untouched. A regular draft retains its exclusive
writer lease and actor. An exported recovery archive contains both histories and
opens with a fresh actor so it can coexist with the original writer; the archive
retains the original authored history, while the new session follows the engine's
fresh-actor undo policy. Exports refuse to overwrite an existing destination.

The reference stores archives locally and offers platform sharing on iOS, macOS
and visionOS. A failed draft save is visible and directs the author to export before
closing. Browser recovery uses its own storage adapter described below. No
automatic destructive repair or protocol cutover is
implied by opening the Apple panel.

## Android reference recovery controls

The Android relay host also imports typed HTTP 409 recovery without advancing
receipts or presence. Its version-2 `AtomicFile` envelope keeps accepted snapshots
and pending proposals separate, reads legacy version 1 without resetting the actor,
and preserves incompatible or malformed proposals on disk. Recovery archives open
with a fresh actor and refuse to overwrite an existing destination. Closed hosts
ignore late exchange completion rather than accessing a disposed session.

The Compose panel offers original-block wrapping, archive export, retry and a
system sharing action. Accepted text remains selectable in read-only fields;
ordinary edit/undo/block actions wait until repair. Failed repairs retain the
proposal and show their error. Archive sharing grants read access only to the
explicitly chosen file through a provider restricted to the recovery directory.
Existing `BlockEditor` callers retain their default editing API; the host opts
into the new read-only overload and error callback.

Nested toggle/list/table text renders in the reference, so repaired content can be
read and selected instead of being hidden by a preservation placeholder. Checked
list state is exposed through a disabled native checkbox. These readers do not
complete nested authoring, rich inline formatting or structural focus acceptance.

Run `bun run test:android:recovery` with `ANDROID_HOME`, `ANDROID_SERIAL` and an
existing `GRADLE_BIN`/Java setup. It starts separate v1/v2 loopback relays, builds
and installs the demo and packaged-library tests on the selected emulator, checks
instrumentation results and cleans up both servers. No production backend is used.
It also force-stops the demo between three separately instrumented recovery phases.
The relay is stopped entirely while the second process restores and repairs its
pending proposal without a token. A third process reopens the repaired draft,
reconnects to the restarted server and compares the accepted document with a fresh
peer. The saved author identity, accepted snapshot and proposal are checked across
the first restart; the repaired snapshot survives the second restart.

## Browser reference recovery controls

The local browser relay adapter imports HTTP 409 proposals through the WASM session
without advancing accepted receipts or presence. `subscribeRecovery` observes
proposal changes separately from document notifications, including a failed receive
and delayed composition-buffer draining. Hosts can use `getRecoverySnapshot` as a
stable external-store value. Repairs clear the proposal only after engine admission.

The reference offers original root/toggle block wrapping, archive download and
synchronization retry. Accepted rich text remains focusable and selectable with
`contentEditable=false`; code/math fields use native read-only textareas. Ordinary
typing, formatting, block actions, stress edits and undo/redo wait for repair.
Unsupported repairs retain both histories and display the failure. The block
catalogue uses original creation payloads and stable origin identities rather than
an invalid merged preview. Broader table/list repair controls remain separate work.

IndexedDB database version 2 stores an atomic envelope with separate accepted
snapshot and pending proposal fields. Legacy unversioned browser drafts retain
their actor and history and upgrade on save. Old bundles requesting database
version 1 fail explicitly, preventing them from overwriting a retained proposal.
Malformed histories, incompatible versions and proposals for another document
fail before writing; stored input stays intact. The exclusive writer lock remains.

Persistence also runs when rejection changes only the pending proposal. Quota or
transaction failure remains visible; retry saves the current accepted/pending
envelope, and an archive download can retain both histories before closing. Archive
downloads are versioned host records separate from the collaboration protocol.
Browser archive-file import and full network-disabled asset loading remain open.

Fourteen Chromium/WebKit host checks pass. A real v2 relay workflow exercises
HTTP 409, failed local storage and retry, accepted text selection, blocked actions,
failed repair preservation, archive download, legacy upgrade and rejection of old
database writers. It closes and reopens the tab with the relay stopped, restores
pending recovery without a token or relay request, repairs offline, closes/reopens
the repaired draft and reconnects to a restarted server. A fresh Swift peer has
the same document with both authors' content. Four incompatible/malformed draft
cases preserve the stored input. These are tab-restart checks with locally served
UI/WASM assets, not full browser-process restart or airplane-mode acceptance.
Firefox host recovery, system input/accessibility and production React migration stay
open.

## Evidence

`Fixtures/recovery.json` executes the same rejected union, receipt/save invariants,
separate proposal restoration, repair, synchronization, reopening and remote author
undo through native Swift, Android JNI and actual WASM in all three browser engines
under the [runtime CI contract](runtime-ci.md). The typed
Kotlin and TypeScript APIs have additional runtime checks.

The generated recovery campaign is reproducible with
`python3 scripts/generate-recovery-history.py`; CI checks `--check`. It retains
all original 261 recovery commands and their expectations, then appends 404
commands across nine histories, with 80 independently constructed expected
documents. Four fixed seeds exercise marked Unicode and atomic references through
concurrent repairs, duplicate delivery, undo/redo of both winning and losing repairs,
and accepted-state restart.
Three depth cases (17, 20 and 22 toggle levels per original chain) begin with valid
offline histories, reject their over-deep union, and preserve both authors through
concurrent repairs. Two math-expression cases begin with 9,998 or 9,999 UTF-16
units: simultaneous one-unit insertions respectively meet or exceed the actual
10,000-unit field limit. The valid case preserves the other author's insertion
through undo; the rejected case keeps accepted receipts and snapshots unchanged
and recreates the exact proposal after separate restore/resubmission. An over-limit
field is retained for explicit recovery rather than automatically trimmed.

`GeneratedRecoveryTests` adds 20 native cases across four seeds and all five
collection kinds (root, toggle children, list items, table rows and table cells).
Each imports third-author metadata edits while recovery is pending, retains a
failed repair, exports/restores the proposal, resolves competing repairs with
duplicate/reordered delivery, checks exact document content against an independent
oracle, then checks undo/redo of the winning and losing repairs and accepted-state
reopening. The existing direct
32 MB document, 64 MB retained-history and 10,000-root checks remain separate from
the smaller shared fixture; passing the generated cases does not replace those
actual resource boundaries or accept full reference-host interaction.

Swift tests independently exercise concurrent repairs, duplicate/reordered additional
histories, invalid repairs and protocol failures, read-only preparation/reentry,
required-content undo, Unicode/marks/references, nesting thresholds, the 10,000-root
boundary and oversized document/capacity retention. Iterative validation and tree
materialization avoid recursive stack overflow on deep rejected unions. A relay test
uses independent Swift processes and HTTP 409 recovery across server/client restart.

Five actual app workflows pass on iPhone and iPad Simulators running OS 27. The new
recovery workflow receives a real v2 rejection, exports its history, restarts
offline with recovery still pending, explicitly wraps the conflicting original
block through the panel, reconnects and verifies both authors converge without
losing either block. Storage tests separately cover failed repair preservation,
fresh-actor archive opening, legacy upgrade and incompatible recovery retention.
These checks do not establish OS 26 minimum-runtime, macOS/visionOS/watchOS/tvOS
interaction or Android/browser recovery acceptance.

On Android API 35 arm64, the recovery runner passes 15 packaged-library checks,
seven ordinary demo checks and all three separately invoked recovery restart phases.
The ordinary demo run reports nine tests with two explicit phase-gated skips; the
new recovery phase is then executed three times, while the existing default-v1
process-restart test retains its separate command. The actual Compose workflow
verifies HTTP 409 recovery, selectable accepted text, disabled ordinary actions,
archive export, offline Activity recreation, explicit wrapping and convergence.
Screenshots show the pending panel and both authors' content after repair. Storage
checks verify legacy upgrades, malformed/incompatible proposal retention, failed
repair preservation, archive actor isolation and refusal to overwrite an archive.

The rendered-field composition test now owns one Compose input session through
[platform input interception](https://developer.android.com/reference/kotlin/androidx/compose/ui/platform/PlatformTextInputInterceptor).
Creating an additional connection from the focused View let the system keyboard
finish the injected composing range before remote delivery. The owned connection
retains the original receipt, text, selection and author-undo assertions without
lowering the test target SDK. This verifies the Compose/InputConnection boundary;
installed-keyboard/system-IME and TalkBack acceptance remain open, along with
minimum/current-runtime interaction and complete rich authoring. API 26/x86 and
API 35/translated ARM64 engine fixtures execute separately in runtime CI; they
do not establish these input requirements. The runner does not accept those
broader platform requirements or browser recovery.

ST-96 remains open for full recovery integration, expanded generated conflict/resource
coverage and the complete cross-runtime threshold matrix. Remaining platform recovery UI,
minimum/current runtime interaction, Firefox host recovery, post-merge runtime CI,
measured budgets and clean
private consumer installation remain separate gates.
