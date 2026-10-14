# Native model scope and current host interactions

Native field IDs can repeat across documents, epochs and authors. The original
coordinator kept its first model while SwiftUI reused the field-only identity;
new typing failed to reach the new session. An empty-document control likewise
kept its first captured paste boundary. Original failures are retained.

The repair scopes an input by its model lifetime plus immutable field, and scopes
the empty control's state/boundary by its owning model. A model's replacement now
recreates the appropriate coordinator while ordinary same-model updates preserve
composition. The old coordinator retains its model, so an object address cannot
be reused to revive that identity while the control exists. IDs remain local and
never enter saved documents/history.

A second reproduced failure kept old Return/boundary callbacks and clipboard
access after host props changed. AppKit/UIKit updates now refresh those handlers
on the existing control; native marked text, input identity and first responder
survive. Synthetic clipboard services keep the real system clipboard untouched.

The repaired tests verify document, epoch, author and same-envelope model swaps;
new typing goes only to the new session. Empty original marked text survives with
its original request ID, payload, document/epoch and captured boundary in the old
host checkpoint, while a new empty document accepts its own input. Native detach
ends marked text and changes retry reason from compositionActive to awaitingCommit;
the original overly strict reason assertion and diagnostic are retained. Recovery
is inert. Host callback/clipboard changes use current services after composition.

All 104 Apple regression tests pass, including the new scope/interaction checks,
prior accessibility labels, composition, window focus, clipboard, persistence and
real process restart suites. Both iOS and visionOS simulator targets compile;
this is not simulator interaction, physical hardware or full VoiceOver acceptance.
Final clean JS/declarations/WASM/JNI builds share the current source. Archived
prior receipts and exact final hashes prove all runtime bytes remain identical
after these native-only changes; earlier browser/shared/timing evidence retains
its original source. No performance campaign was repeated or accepted here.

Full prototype, native/browser/assistive/resource/private-install campaigns,
current hosted CI/review and deferred physical/final acceptance remain open.
Protected main, private 0.2.0 and concurrent Foliostrate work are unchanged.
[Receipt](receipt.json), [artifact identities](artifact-identity.json) and
[hashes](hashes.json) pin the results and original failures.
