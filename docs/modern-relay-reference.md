# Modern local relay integration

The optional protocol 7 reference exercises shared document format 1 through
the actual Swift engine, browser WASM, local disk and IndexedDB. It preserves
legacy protocol 1/2 reference entrypoints. This is a loopback development service;
Foliostrate still owns production authorization, synchronization scheduling,
storage policy and rollout.

## Run

Install the repository's pinned dependencies and matching actual WASM first.
Use a separate data directory for modern rooms:

```sh
DEMO_TOKEN=local-test DEMO_DATA=.local-modern-demo bun run demo:relay:modern
bun run demo:dev
```

Open `/block-editor/modern-relay.html`, choose a room and a distinct author per
independent replica, and enter the local token. `Synchronize` exchanges changes;
`Save locally` pairs the accepted session, author selection history, provider
records, recovery, held packets, original drafts and the server receipt.
The example has explicit save/sync controls rather than library-owned timers.
The existing modern local example supplies the broader application asset picker;
this collaboration example resolves already-stored application assets.

Only room identifiers containing letters, numbers, hyphens or underscores are
used as file names. Each room becomes its document identity. Its configured
epoch and saved format must match; incompatible or corrupt originals produce
an explicit error, never a new empty room or an implicit legacy migration.
One reference server owns a data directory. The service writes a private
temporary file, synchronizes it, renames it atomically, synchronizes the parent
directory and reads back exact bytes before acknowledgment. The Mac/Linux
reference requires directory synchronization support.

## Application API

The new opt-in export is `./swift/modern/relay`. Existing exports remain intact.

```ts
const { relay, resumeDeferred } = await ModernBrowserRelay.open(
  runtime, store, `${documentID}:${actorID}`, {
    documentID, epoch, actorID,
    endpoint: `/relay/rooms/${documentID}`,
    relayKey: "application-owned-service-identity",
    token: applicationToken,
  },
);
```

Supply a stable service identity and actor, not a newly generated actor on every
reopen. A saved local checkpoint opens before any server request and can open
offline with an empty token. A fresh remote document requires a token. Tokens
remain in memory; checkpoints/export contain no token, endpoint credentials or
query strings. Embedded URL credentials and redirects are rejected. A caller
may supply a standard callable `fetch` adapter for its application environment.

Bind `relay.host.session` and `relay.host` to the modern React surface. The
application decides when to save, synchronize and resume retained peer packets.
Restoration holds only packets that were actually retained; an ordinary empty
queue does not suppress future peer editing. Original draft/clipboard/provider
requests remain inert until explicitly retried. A retained merge recovery opens
the accepted document with its proposal available for explicit author repair.
`resumeDeferred()` is idempotent and must wait until the application's input
binding is ready when a retained packet queue exists.

Deactivate/close the relay before disposing or replacing its host. Response
application rechecks connection/token generation and the original host's
activation generation after each asynchronous boundary. A deactivation followed
by reactivation cannot revive an old response. Read-only presentation can still
receive authorized peer work. Host authorization policy continues to control
authoring in the shared engine.

## Acknowledgment and recovery

The server restores a detached Swift session for each request. It validates
caller receipt scope and the complete proposal before durable publication;
rejected unions return `409 modernRecoveryRequired` without a receipt or file
replacement. No client-provided document projection replaces the accepted room.
Presence changes only after accepted persistence, expires independently and
vanishes after a server process restart.

The browser persists before transmission, validates returned receipt/batch
scope through Swift, applies valid peer work, then persists the new server
receipt with the entire host checkpoint before clearing pending counts. A
failed checkpoint save leaves the old confirmed receipt and original work
available for duplicate-safe retry. A failure after disk rename has an unknown
acknowledgment outcome: the next server request reloads actual disk state and a
duplicate proposal remains harmless.

The 8 MB request limit is unchanged and measured in UTF-8 bytes. Exactly
8,000,000 bytes can be admitted; the next byte returns `413` with the maximum,
without a receipt. Larger valid authored content and its original transaction
history remain locally accepted, pending and exportable across restart. Retry
does not truncate history or silently reduce document content. An oversized
history can continue exceeding the transport limit after author Undo; export
and an explicit archival/transport decision are required rather than pretending
Undo removes original history bytes.

The reference's `Undo my rejected changes` action identifies this author's
unacknowledged transactions and invokes shared repair, retaining peer work and
the original log. `Export recovery` exports the complete paired checkpoint.
It does not publish the document or grant a consumer access.

## Verification boundaries

`tests/modern-relay.test.ts` uses separate real server and Swift client processes
for title/appearance/column history, conflict repair, exact capacity boundaries
and disk failures. `tests/modern-relay.swift.ts` uses real browser input, actual
browser/server process exit/restart, IndexedDB, native peers and complete archive
export in Chromium, WebKit and Firefox. Static application assets remain served
locally; this is relay-offline recovery, not a service-worker or disk-cold offline
browser-start claim. `tests/modern-relay-client.contract.ts` adds real WASM/IDB
expectations with deliberate HTTP delay/failure injection for lifecycle edges.

The native Swift/Kotlin modern transport bindings, complete physical/assistive
platform campaigns, broader performance and final product acceptance remain
separate finishing work. The new JavaScript is not the existing published 0.2.0
artifact; private delivery needs a new reviewed version and its concrete approval.
