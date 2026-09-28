# @seventwo-studio/block-editor

Framework-neutral block editor core for structured documents.

This package owns the portable pieces of the editor:

- Zod schemas and TypeScript types for block documents.
- Block factories, transforms, markdown parsing, and markdown serialization.
- Slash command metadata without React or icon dependencies.
- A deterministic CRDT operation layer for insert, update, move, delete, merge, encode, and decode flows.
- A basic React editor surface with CSS variable theming.

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
bunx playwright install chromium
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
document. Literal code/table destinations, ambiguous multi-item list destinations
and empty/rejected imports retain native plain-text paste. Imports over 1 MB of
HTML, 5,000 blocks, 128 levels or 100,000 characters in a code block fall back to
plain text without silently truncating content.

`parseClipboardHtml` and `pasteBlocks` are exported from the package root for custom
surfaces. Parsing requires a browser `Document`; importing the package remains
server-safe. These helpers do not replace server-side schema, link or asset checks.
The existing textarea surface stores marks but does not yet visually render inline
formatting. Browser tests verify the real React paste event, caret, data model,
namespace filtering and absence of remote-image requests.
