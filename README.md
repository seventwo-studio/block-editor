# @seventwo-studio/block-editor

Framework-neutral block editor core for structured documents.

This package owns the portable pieces of the editor:

- Zod schemas and TypeScript types for block documents.
- Block factories, transforms, markdown parsing, and markdown serialization.
- Slash command metadata without React or icon dependencies.
- A deterministic CRDT operation layer for insert, update, move, delete, merge, encode, and decode flows.
- A basic React editor surface with CSS variable theming.

## Shared Swift engine (experimental)

The next engine is implemented in Swift with optional collaboration, a native Apple
reference view, a Kotlin/JNI Android reference, and an asynchronous React/WASM
entrypoint. It is intended for Therein, Foliostrate, Parqeet and an unnamed local-only
editor. The existing React editor remains available during migration.

See [the technical contract, build instructions and open acceptance work](docs/shared-swift-editor.md).
Start with `swift test`, `swift run local-editor` and `swift run collaborative-editor`.
The browser reference is at `/block-editor/swift.html` after `bun run build:wasm`
and `bun run demo:dev`. New npm entrypoints are `./swift` and `./swift/react`;
hosts supply the WASM artifact. No package release is implied.

The [local sync lab](docs/local-sync-lab.md) adds a persistent loopback server,
native Swift HTTP client, browser clients, offline/rejoin controls and seeded stress
tests. Start it with `DEMO_TOKEN=choose-a-local-test-token bun run demo:relay`.

## React UI

```tsx
import { makeBlock } from "@seventwo-studio/block-editor"
import { BlockEditor } from "@seventwo-studio/block-editor/react"
import "@seventwo-studio/block-editor/react.css"
import { useState } from "react"

export function Editor() {
  const [blocks, setBlocks] = useState([makeBlock("paragraph")])

  return (
    <BlockEditor
      value={blocks}
      onChange={setBlocks}
      onOperation={(operation) => console.log(operation)}
      placeholder="Type / for commands"
    />
  )
}
```

The UI is intentionally plain browser React: no app-specific component library,
no Ambiently dependency, and customization through CSS variables such as
`--s2be-bg`, `--s2be-text`, `--s2be-accent`, `--s2be-radius`, and `--s2be-font`.

## Public Entrypoints

- `@seventwo-studio/block-editor`
- `@seventwo-studio/block-editor/model`
- `@seventwo-studio/block-editor/react`
- `@seventwo-studio/block-editor/react.css`
- `@seventwo-studio/block-editor/schema`
- `@seventwo-studio/block-editor/crdt`

## Demo

The repository includes a Vite demo for GitHub Pages. It shows the React editor,
theme customization, emitted UI operations, CRDT operation state, and markdown
serialization side by side.

```sh
bun run demo:dev
bun run demo:build
```

## Verification

```sh
bun install
bun run typecheck
bun run demo:typecheck
bun run test
bunx playwright install chromium webkit
bun run test:browser
bun run build
bun run demo:build
```

## Visual-only editing

Pass `allowMarkdown={false}` to `BlockEditor` to hide the raw Markdown editor.
Block editing, slash commands and Markdown typing shortcuts remain available.
The default is `true`, preserving existing integrations.

```tsx
<BlockEditor value={blocks} onChange={setBlocks} allowMarkdown={false} />
```

If the prop changes to `false` while raw editing is open, the current draft is
converted to blocks and emitted through `onChange` and the existing `markdown`
operation, just like pressing **Done**. The draft is not silently discarded.
This prop controls editor UI; consumers still validate document content and
permissions at their own application boundary.

## Updating inline text

`setBlockText` uses `updateInlineText` for inline content. Plain-text edits retain
formatting and structured references outside the changed range rather than
flattening the whole field. New text inherits the adjacent edited text span's
marks. A reference whose label is partially edited becomes ordinary text, so it
cannot silently retain an incorrect entity identity. Unicode comparisons use
code points to avoid splitting surrogate pairs.

`updateInlineText` treats the difference between two plain-text values as one
contiguous replacement. For editors with explicit selections and richer editing
operations, use the structured `InlineNode` model directly. This helper does not
sanitize links, implement visual formatting controls, or resolve concurrent edits.

## Internal package distribution

Release `@seventwo-studio/block-editor` through the GitHub npm registry. The repository
may be public; this does not authorize a public package release. `.npmrc` and
`publishConfig.registry` route this scope to `https://npm.pkg.github.com`.

The **Internal package release** workflow is manual and runs only from the repository's
current default branch. Supply the exact reviewed `package.json` version and confirm
that package access and any additional spending are approved. Merging a PR does not
publish a package. The workflow validates types, tests and demo, installs a real tarball
in an isolated consumer, then publishes with its short-lived `GITHUB_TOKEN`.
It rejects an existing package that is not private and checks visibility after publishing.
GitHub creates new packages as private by default; do not change them to public.

Before the first release, check organization package usage/budgets and obtain approval
for any new charges. Enterprise Cloud includes 50 GB of storage (shared with Actions
artifacts) and 100 GB monthly transfer; downloads authenticated with `GITHUB_TOKEN`
in Actions do not consume package transfer allowance. See [GitHub Packages billing](https://docs.github.com/en/billing/concepts/product-billing/github-packages).
These allowances do not establish current remaining capacity or spending approval.

After publication, open the package's settings and explicitly grant **Read** under
**Manage Actions access** to `seventwo-studio/foliostrate`. Keep access limited to approved
consumers; verify inherited access before granting anything broader. In Foliostrate CI,
use `permissions: packages: read`, authenticate with its own `GITHUB_TOKEN`, and verify
installation from a clean lockfile. Local developers need an authorized classic token
with `read:packages`, stored outside the repository. Never commit tokens.

Consumers add `@seventwo-studio:registry=https://npm.pkg.github.com` to their project
`.npmrc` and pin an exact published version. For example, after **0.1.0 is confirmed
published and accessible**:

```sh
npm install --save-exact @seventwo-studio/block-editor@0.1.0
```

Foliostrate configures `allowMarkdown={false}` and owns authorization, asset validation,
uploads, autosave and publication. Publishing this package does not implement those
features. The package's broader block schema is not an application authorization policy.

`bun run check:package` requires Node and npm and validates all packaged entrypoints,
CSS, a schema parse and React server rendering from a fresh installation. It neither
publishes a package nor relies on source aliases.

## Formatted clipboard paste

The React editor imports HTML clipboard content into the shared document model:
paragraphs, headings (up to level three), flat bullet/numbered lists, quotes, code
and dividers, with bold, italic, inline code and absolute HTTP(S)/email links.
Unsupported formatting becomes text; nested lists flatten and table cells become
tab-separated text. Script, style, embedded and foreign-namespace content is
removed. Images contribute only their alt text: hosts must upload and authorize
assets through their own integration. Clipboard HTML is parsed in a detached inert
template and never rendered or attached to the page.

Pasting replaces the active text selection, preserves surrounding marks/references
and places the caret before the preserved suffix. A single `paste` UI operation
contains `before` and the ordered replacement `blocks`; replace that original block
at its current position when replaying it. `onChange` supplies the full resulting
document. Literal code/table destinations and ambiguous multi-item list destinations retain
native plain-text paste. Empty/rejected HTML imports in the visual inline surface
use the clipboard plain-text alternative. Imports over 1 MB of
HTML, 5,000 blocks, 128 levels or 100,000 characters in a code block fall back to
plain text without silently truncating content.

`parseClipboardHtml` and `pasteBlocks` are exported from the package root for custom
surfaces. Parsing requires a browser `Document`; importing the package remains
server-safe. These helpers do not replace server-side schema, link or asset checks.
The custom inline surface renders stored marks while editing. Browser tests verify the real React paste event, caret, data model,
namespace filtering and absence of remote-image requests.


## Visual inline editing

Paragraphs, headings, quotes, callouts and flat single-item list blocks use a custom
contenteditable surface backed by the canonical inline model. Bold, italic, inline
code and links render directly while typing; an in-place toolbar applies formatting
to the selection. Bold/italic/code also toggle the marks for subsequent typing at a
collapsed caret. Link addresses must be absolute HTTP(S) or mailto URLs, and clicking
a link in the editor does not navigate away. Reference nodes remain structured when
unaffected by edits; partial edits to a reference label become ordinary text.

Use Cmd/Ctrl+B, I and E for bold, italic and code; Cmd/Ctrl+K opens the inline link
form. Enter splits at the selection while preserving marks on either side;
Shift+Enter inserts a line break. Browser edit ranges handle repeated text without
moving formatting to the wrong occurrence. Composition is deferred until completion.
HTML and plain-text paste update the model; browser HTML is never reused as rendered
markup. Text drops and edits spanning multiple editable blocks are not supported;
use the existing block selection/reordering controls for operations across blocks.

Undo/Redo buttons, Cmd/Ctrl+Z, Cmd/Ctrl+Shift+Z, Ctrl+Y and native history input events
use up to 100 document snapshots. A genuinely new external `value` resets local
history; parent echoes do not. History is local to this editor session and does not
provide collaboration or server revision history. `split` operations carry `before`
and replacement `blocks`, like paste; `undo`/`redo` carry the restored full `blocks`.
Code and table cells retain literal editing surfaces. Hosts supply the image upload and resolution callbacks described below.


## Host-controlled images

Provide `imageUpload` to enable Add image and Replace image, and
`resolveImageSource` to display image blocks. Upload callbacks return `{ src, alt?,
width?, height? }`; `src` can be an opaque asset ID. The editor validates that shape
and persists only those fields, preserving the block ID and caption on replacement.
Changing the description updates the image's alt text. Empty alt text does not make
an image block disposable when Backspace is pressed in its description field.

```tsx
<BlockEditor
  documentKey={`${scopeId}:${entryId}:${language}`}
  value={blocks}
  onChange={setBlocks}
  allowMarkdown={false}
  imageUpload={{
    mimeTypes: ["image/png", "image/jpeg", "image/webp"],
    maxBytes: 5 * 1024 * 1024,
    upload: (file, { signal }) => uploadHelpImage(file, { signal }),
  }}
  resolveImageSource={(assetId) => authorizedMediaUrl(assetId)}
/>
```

`uploadHelpImage` and `authorizedMediaUrl` above are host functions, not package
APIs. The host owns authentication, byte-level validation, size limits, tenant/app
ownership, storage, asset access, autosave and reference-aware retention. Declared
MIME/size checks in the editor only catch obvious mistakes before invoking the host.
The editor does not accept pasted remote images as uploads or configure storage.

No resolver means no image request: arbitrary stored `src` strings are never fetched
implicitly. Resolved URLs may be HTTP(S), blob previews or root-relative API paths;
active/data/file and protocol-relative URLs are rejected. Rendering is not an
ownership check. Loading failures show an explicit preview retry, independent from
upload retry. Host upload failures retain the selected file for retry without adding
a broken block. Only completed, validated uploads enter the document.

Cancel, unmount and replacement of the external document abort pending uploads and
ignore late results. Pass a stable `documentKey` for the scope/entry/language, even
when two documents contain identical blocks; changing it also resets local history
and selection. Hosts may instead remount the editor with a React `key`. Parent
echoes of the editor's own changes keep uploads running. If a successful upload
cannot be inserted because the document became full, retry reuses that asset rather
than uploading it twice. Cancelled/failed/replaced or undone assets may remain in
storage: the host must clean them up according to saved draft/published references,
not delete them immediately from a client callback.

The public demo decodes PNG/JPEG/WebP files into local blob previews and stores demo
asset IDs for the lifetime of the tab. It does not upload files. The separate
`images-test.html` development fixture exercises host failures and cancellation and
is not a demo build entry.

### Host block controls

`allowedBlockTypes` restricts newly authored block types. Omit it to preserve the
full editor; paragraphs always remain available for empty documents and plain-text
fallback. The type is exported as `AuthoringBlockType` from the root package.

```tsx
<BlockEditor
  value={blocks}
  onChange={setBlocks}
  allowMarkdown={false}
  allowedBlockTypes={[
    "paragraph", "heading1", "heading2", "heading3", "bullet", "ordered",
    "quote", "code", "divider", "image",
  ]}
  imageUpload={imageUpload}
  resolveImageSource={resolveImageSource}
/>
```

The configuration filters slash commands, conversion controls, typing shortcuts,
Enter continuation and image insertion. Rich paste and raw Markdown imports reduce
unsupported blocks to paragraphs retaining their text. Disallowed typing shortcuts
remain literal text. Existing host-provided content and undo history are preserved;
changing the configuration never silently rewrites saved documents. Loading a new
document should still change `documentKey` to reset history.

These are authoring controls, not server-side document validation. Hosts must still
validate the document schema, allowed inline nodes/marks, nesting, link URLs and
asset ownership before saving. Existing unsupported blocks may still be edited or
deleted; migrations of saved content require an explicit host workflow.
