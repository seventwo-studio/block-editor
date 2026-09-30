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
The relay's existing 8 MB request limit remains separate from engine capacity.

The engine retains proposals only within 100,000 changes and 64 MB of encoded batch
data, reserving a deterministic allowance for author history and JSON envelopes so
an admitted save remains restorable. Materialized documents retain the 10,000 root block, 100 JSON nesting and
32 MB limits. If combining an additional batch exceeds retained capacity,
`recoveryCapacityExceeded` leaves the previous proposal and accepted state intact.
The caller must retain that rejected input separately; it is not acknowledged.

Before any explicit partition or epoch cutover, archive accepted history, the
pending proposal and every unacknowledged input, stop old writers and reconcile
their drafts. Never clear a pending proposal, truncate history, reinterpret versions
or discard content to make a limit pass. Automatic partitioning, compaction and a
host-facing recovery UI are not delivered here; they require explicit integration
and further acceptance. A bounded recoverable outcome is not unrestricted merge
convergence or an accepted performance budget.

## Evidence

`Fixtures/recovery.json` executes the same rejected union, receipt/save invariants,
separate proposal restoration, repair, synchronization, reopening and remote author
undo through native Swift, Android JNI and actual WASM in Chromium/WebKit. The typed
Kotlin and TypeScript APIs have additional runtime checks.

Swift tests independently exercise concurrent repairs, duplicate/reordered additional
histories, invalid repairs and protocol failures, read-only preparation/reentry,
required-content undo, Unicode/marks/references, nesting thresholds, the 10,000-root
boundary and oversized document/capacity retention. Iterative validation and tree
materialization avoid recursive stack overflow on deep rejected unions. A relay test
uses independent Swift processes and HTTP 409 recovery across server/client restart.

ST-96 remains open for full recovery integration, expanded generated conflict/resource
coverage and the complete cross-runtime threshold matrix. Platform recovery UI,
minimum/current runtime interaction, Firefox, runtime CI, measured budgets and clean
private consumer installation remain separate gates.
