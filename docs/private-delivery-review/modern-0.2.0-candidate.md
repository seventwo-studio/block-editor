# Private modern 0.2.0 candidate proposal

Owner: ST-34; actual handoff: ST-144. This updates the proposed version for the
accepted P-ST-85 batch. The older recovery proposal, original exposure evidence
and separately approved deletion remain historical records. This document and
local staging do not provision, publish, grant access or change billing.

| Proposed action | Exact boundary |
| --- | --- |
| Publisher | Create/use private `seventwo-studio/block-editor-internal-packages` after authenticated name/visibility/maintainer inventory and concrete approval. A 403 or ambiguous 404 is not name-availability evidence. |
| npm identity/version | New private `@seventwo-studio/block-editor-internal@0.2.0`; never overwrite an existing version or reuse the removed exposed publication. |
| Source/artifacts | Reviewed immutable source commit/tree from PR #70, all commits landing on protected main GitHub Verified, successful fresh required CI/reviews, matching actual JS/WASM receipts and tarball integrity. |
| Permissions | Private publisher Actions Admin for delivery; only private `seventwo-studio/foliostrate` Actions Read for consumption. Existing approved maintainers only. No public source Actions grant or other consumers. |
| Credentials | Publisher/consumer use their own ephemeral job tokens; no PAT expansion, exported signing keys or cross-repository publisher credentials. |
| Budget | Keep $0 Packages cap and Stop usage. Refresh controls and included allowance before publication; no paid overage. |
| Verification | Private metadata and exact access inventory, approved clean consumer install/read; negative access checks only within separately approved grant-change scope. Anonymous denial alone is not proof of private access. |

GitHub currently documents that a package created by an Actions job token
inherits its publishing repository's visibility and permission model. The
private publisher boundary therefore precedes first publication; a post-publish
check cannot undo an accidental public first publication. Source:
[GitHub Actions package defaults](https://docs.github.com/en/packages/managing-github-packages-using-github-actions-workflows/publishing-and-installing-a-package-with-github-actions#default-permissions-and-access-settings-for-packages-modified-through-workflows).

## Local preparation

Build actual WASM, JavaScript/declarations and both JNI architectures from one
clean source. Generate checked provenance, then run:

```sh
node scripts/prepare-private-modern-package.mjs /absolute/new/candidate-directory REVIEWED_40_CHARACTER_SOURCE_SHA
```

The output directory must not exist. npm's admitted file inventory is copied to
an isolated directory. Only the distribution identity and repository association
are transformed; all engine/runtime artifacts retain their source hashes.
`modern-provenance.json` records original and transformed manifest digests, exact
source/tree, proposed publisher and package identity. The generic package checker
installs that tarball and executes actual WASM with the replacement imports.
`private-candidate.json` records packed/unpacked sizes, SHA-512 integrity,
tarball SHA-256 and runtime hashes. Nothing is sent to a registry.

The private publisher must fetch only the approved immutable source, check its
GitHub Verified delivery/CI/reviews and use these scripts against matching
rebuilds. Apply the existing `release-guards.mjs` to authenticated publisher and
package metadata. A reviewed first-publication 404 is permitted only from that
verified private publisher; 401/403/429, malformed/unknown responses or existing
public/internal metadata stop publication. Check private visibility immediately
after creation and before consumer grants. Do not enable any publisher workflow
on the public source repository.

## Usable handoff

After actual private publication, record the registry's exact immutable version,
integrity and tarball URL with publisher/source/consumer CI identities. Foliostrate
pins that release using its own Actions Read token and a fresh isolated store.
Preserve its current manifest, lockfile, autosave conflicts, authorization and
publication boundaries; source substitution is not private registry acceptance.
The [modern handoff](../modern-editor-handoff.md) describes the richer-document
API boundary and runnable local examples. ST-9/ST-111 own application integration.

ST-34/ST-144 stay open until actual artifacts, approved consumer access and the
usable handoff exist. Comprehensive all-runtime installation, devices,
accessibility/performance and final product acceptance remain in finishing.
