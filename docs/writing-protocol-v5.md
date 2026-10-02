# Explicit writing protocol 5 epoch

Protocol 5 adds an explicit `spliceBoundary` descriptor for ordering a complete imported block group at one retained paragraph cut. Start it with the explicit Swift protocol version, TypeScript `createWritingV5`, or Kotlin `createV5` constructor. Creating an epoch does not upgrade a saved protocol 3 or 4 history. Stop old writers and preserve their history before a deliberate cutover; mixed versions are rejected before accepted state or receipts change. Version 6 remains unsupported.

Protocols 4 and 5 share the existing finite retained-origin, observed-cohort, schema-role, Unicode, author-history and accepted/pending recovery rules. Existing constructors, saves, restores, receipts, fixture inputs and old operation projection retain their original versions and semantics. The additive native Apple model still requires protocol 4; this engine change alone does not migrate a platform editor.

## Whole imported blocks in a paragraph field

`pasteBlocks` replaces one anchored paragraph-field range with complete `.node` block parts. It allocates one authored change and one globally unique element-ID sequence, freshens only schema-defined identities recursively, and keeps rich references, marks and unknown metadata intact. Clipboard data is inert. Host block/mark restrictions and explicit asset-metadata policy apply before accepted mutation; paste does not fetch or upload assets.

At offset zero, imports precede the original suffix owner, preserving its origin and metadata without an empty prefix. At a positive offset, the original owner keeps its prefix; imports and a fresh suffix continuation form one recorded birth chain. A continuation is retained even when its text is empty, providing an explicit caret owner and preserving boundary metadata. This bounded API rejects inline parts, different fields, non-paragraph targets and active composition. Single inline replacements and explicit collection imports retain their existing APIs.

The descriptor names the source and suffix fields, retained text edge, observed outer neighbor, and ordered same-edit root members ending in the suffix. Admission validates a schema-compatible contiguous birth chain rooted in a proven source placement; a validated retained paragraph-role proof permits a public paragraph originally born as an item. Member ownership, duplicate destinations, same-edit member moves and unobserved same-edit outer neighbors are invalid packets even when an author Undo disables the edit. Member and outer-neighbor admission uses indexed sets rather than repeated whole-edit scans.

Projection sorts whole groups by retained cut rank. A captured `before` reference to any imported member orders the new cut before that member's complete group, including sequential paste or ordinary split at an existing boundary. A later independent move remains authoritative; the projector rewrites only selected original births. Incompatible ownership constraints retain the union as recovery instead of replacing arrays or dropping peer history. Author Undo preserves foreign moves, descendant births and text; Redo restores the author's retained births without duplication.

## Verification and remaining scope

Independent Swift witnesses cover both actor orders and distinct cuts, duplicate and reversed delivery, exact rich metadata, stable caret, both authors' Undo/Redo, reopen, repeated same-boundary paste, ordinary split before an imported group, malformed active/inactive ownership, exposed paragraph roles, and foreign moved containers with unseen children. Typed Kotlin and actual WASM witnesses and the shared literal transcript must execute on the same candidate before integration.

General inline-segment absorption, mixed/cross-block selection planning, raw HTML adapters, platform clipboard input and all ST-100 acceptance criteria remain open. Preserve historical measurements with their original source identity; this new engine needs current-source release measurements.
