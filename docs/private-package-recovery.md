# Private package recovery proposal

Prepare a replacement private npm publication through a private publisher
repository, retire the exposed package from approved consumption, and verify a
pinned Foliostrate install using its own Actions token. This proposal is for review
under [ST-34](https://linear.app/seventwo/issue/ST-34/prepare-internal-package-delivery).
It does not approve repository creation, publication, permission changes or deletion.
Record the accepted choices and exact revision in the existing
[confirmed package decision](https://app.notion.com/p/3e7bb04960098157bdd8e718feb4227d)
and ST-34 before implementing recovery.

## Current evidence

The package-settings inspection on 1 October 2026 showed
`@seventwo-studio/block-editor` as **Public**, with repository access inherited from
the public `seventwo-studio/block-editor` source repository. Actions access listed
only the source repository as Admin; Foliostrate had no grant. Foliostrate's
repository is private. The current CLI credential lacks `read:packages`, so its
package metadata request returned 403. Anonymous npm metadata returned 401; that
response does not establish privacy because npm authentication is required for
public GitHub packages too.
[GitHub's registry authentication rules](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-npm-registry)
describe that distinction.

Source inspected at `e787146c432e649e71a1a6423fe4a24c55e21f5c`:

- `package.json` names `@seventwo-studio/block-editor@0.1.0` and targets GitHub's
  npm registry. Its explicit files list excludes the compiled WASM module.
- `.github/workflows/package.yml` checks existing visibility, permits a 404 before
  publishing, and checks privacy after publication. It cannot repair a public
  identity or establish a safe private first publication from a public repository.
- `scripts/check-package.mjs` validates a local tarball install and exported
  JavaScript/types/CSS. It explicitly rejects packaged `.wasm` files. This is not
  a private-registry consumer install or runnable WASM-package acceptance.
- SwiftPM products and an Android library exist, but the Android Gradle module
  has no reviewed private publication configuration. Passing runtime fixtures
  does not establish distribution acceptance for any platform.

The later read-only refresh on 1 October 2026 confirmed the source repository is
public and its default branch is `codex/initial-extract`, at
`e7d616a0262eac4c368fdcf83f18890b5a83e5ac` (GitHub Verified). The workflow and
tarball checker are unchanged from the inspected revision; package identity,
exports and WASM exclusion are unchanged. The
[failed release run](https://github.com/seventwo-studio/block-editor/actions/runs/36475566396)
records successful publication before the final privacy check failed.
The existing CLI credential still returns 403 for package metadata, so current
versions, grants, downloads and visibility have not been refreshed through REST.
No credential expansion is approved. A GET for the proposed publisher returns
404, which means absent or inaccessible, not verified name availability.

Foliostrate is private at source
`92b4755ae242efe5d684f1faba4387b5788f4317`, with `pnpm@11.25.0` and
`pnpm-lock.yaml` format `9.0`. Its current root manifest has no editor dependency.
Its consumer acceptance procedure below uses that toolchain. These observations
do not select a release source or approve recovery.

The approved spending boundary remains a **$0 GitHub Packages cap with Stop usage**.
Publication must stop when the included allowance is unavailable. Current billing
headroom and the exact budget control must be rechecked before execution; the
decision records establish the constraint, not a current usage measurement.

## Recommended choices for review

| Choice | Recommendation |
| --- | --- |
| npm identity | `@seventwo-studio/block-editor-internal`, initial exact version `0.1.0` |
| Publisher | New private `seventwo-studio/block-editor-internal-packages` repository, created only after approval |
| Source | Preserve public `seventwo-studio/block-editor`; publish only a reviewed immutable source revision |
| Package visibility | Private, never Internal or Public |
| Human access | Existing organization owners and only the approved delivery maintainers; no new team/member grant implied |
| Actions access | Private publisher Admin for delivery; private `seventwo-studio/foliostrate` Read for consumption |
| Public source Actions | No replacement-package grant; public source CI produces verification evidence without registry credentials |
| Other consumers | No grants until separately approved; naming Therein, Parqeet or the local editor is not access authorization |
| Exposed identity | No new versions or approved consumer references; select one of the treatments below before declaring recovery complete |

The replacement identity separates the failed publication from future delivery
without overwriting its version. Check name availability in authenticated package
settings before creation; 401/403 must fail the check rather than be treated as
absence. If occupied, return for review with a specific alternative name.

A private publisher gives first publication a private repository boundary.
[GitHub documents](https://docs.github.com/en/packages/managing-github-packages-using-github-actions-workflows/publishing-and-installing-a-package-with-github-actions)
that packages first created by an Actions token inherit the publishing
repository's visibility and permissions model by default. Do not first publish
from the public source and rely on a later visibility check. Keep the package
linked only to the private publisher; public-source links belong in provenance,
not in package repository-inheritance metadata. After first creation, inspect
granular access, remove inheritance if necessary, then explicitly restore only
the intended maintainers and Actions grants. Changing inheritance can replace
existing grants, so inventory and recheck them.
[GitHub's access-control instructions](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)
support separate npm permissions. Do not alter organization-wide inheritance
defaults or source-repository visibility for this recovery.

### Treatment of the exposed publication

GitHub does not allow a public package to become private again.
[Visibility documentation](https://docs.github.com/en/enterprise-cloud%40latest/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)
therefore rules out an in-place private conversion.

1. **Preserve and retire:** retain the exposed `0.1.0` as historical evidence, stop
   publishing to that identity, record it as excluded from approved consumption,
   and move consumers to the replacement. This requires an explicit decision to
   accept the remaining exposed publication; private replacement alone does not
   satisfy ST-34's exposed-publication criterion.
2. **Remove after explicit approval:** recommend removing the exposed identity
   after inventorying all versions and consumers and preserving a restricted
   evidence copy. The exact target is the npm package `block-editor` under
   `seventwo-studio`, not the source repository or replacement. If versions beyond
   `0.1.0` exist, enumerate them and obtain approval for the exact deletion scope.
   Until approval, perform no delete/deprecate/unpublish action. Do not reuse the
   old namespace for a new private package.

Before any approved removal, retain metadata, version IDs, checksums, release
source/run, access inventory and evidence of the exposure. Inventory downloads
and known dependencies; deletion may break unknown consumers. GitHub permits
deletion of a public version with at most 5,000 downloads; higher counts require
Support. Restoration is conditional on the namespace remaining free and the
30-day window. Removing a publication cannot recall downloaded copies.
[Deletion and restoration rules](https://docs.github.com/en/packages/learn-github-packages/deleting-and-restoring-a-package)
define those limits. Do not broaden token scopes to perform removal: use the
existing authenticated administrative UI after exact approval, or stop if its
authority is insufficient.

## Execution sequence after the reviewed decision

The source change prepared in [PR #64](https://github.com/seventwo-studio/block-editor/pull/64)
replaces the old release workflow with local candidate validation. It retains
version, type, test, build and tarball checks, uses only `contents: read`, and
removes registry publication, registry authentication and the spending-approval
checkbox. Until this PR is delivered, the live default workflow retains its old
behavior. This change does not establish private package recovery: inventory,
the exact removal/access/publication decision, the $0 cap with Stop usage and
clean private consumer acceptance remain required. No replacement identity or
hosting contract is selected by the source change.

1. Link the accepted proposal revision, identity, publisher, exposed-package
   treatment and administrator in ST-34. A documentation merge is not this
   decision. Preserve the issue's native prerequisites and unchecked criteria.
2. Inspect organization billing: Packages budget remains $0 with Stop usage;
   record current included storage/transfer usage and planned artifact sizes.
   Storage includes retained versions and shared Actions artifacts. Never raise
   the budget, disable Stop usage, remove unrelated archives or switch visibility
   to bypass the limit. Actions downloads authenticated with `GITHUB_TOKEN` avoid
   transfer charges under GitHub's documented model, but storage still counts.
   [Billing rules](https://docs.github.com/en/billing/concepts/product-billing/github-packages)
   apply to the publisher and consumer jobs.
3. Create the approved private publisher repository and verify its visibility and
   maintainers before any artifact upload. Keep its publication workflow manually
   dispatched on a protected reviewed revision. Fetch the public engine by exact
   commit, with no cross-repository credential or mutable branch dependency.
4. Review the delivery implementation for manifest identity, provenance,
   publication guards and checks. Replace all hard-coded old-identity checks;
   don't dispatch the existing source publication workflow. Build a local packed
   candidate and inspect its file inventory, size, checksums and exports. No
   credentials, local paths, development caches or unrelated fixtures may enter
   the package.
   Retire the public source workflow's publication capability through that
   reviewed change and remove the dispatch input that implies additional spending
   can be approved by a checkbox. Keep public-source verification credential-free.
5. Publish from the verified private publisher using its ephemeral job token with
   `contents: read` and `packages: write`. Permit first creation only with the
   explicit approved identity and verified private publisher; subsequent releases
   require package metadata `visibility == private`. Unknown metadata responses
   fail closed. Verify privacy immediately after first publication and before
   granting consumer access. Failure stops consumer delivery and opens recovery;
   no automatic deletion or public fallback.
6. Inventory package access and grant only Foliostrate Actions **Read**. Its
   install job uses `contents: read`, `packages: read` and its own `GITHUB_TOKEN`.
   Do not put a publisher token, personal token or registry credential in the
   Foliostrate repository. Test authorized installation and rejected publication
   authority without attempting a write. Verify Foliostrate remains private;
   do not run private-package jobs on untrusted fork code or `pull_request_target`.
7. Execute the pinned clean install below. Record exact package version,
   registry integrity, source commit, consumer commit and successful CI URL.
   Complete the chosen exposed-publication treatment with its required approval
   and evidence. Only then assess each ST-34 criterion independently.

## Pinned clean Foliostrate install

Use the reviewed replacement `0.1.0` manifest and lockfile with its resolved
GitHub registry URL and integrity. Keep source imports updated for the replacement
name. A local tarball, `file:`, `link:`, workspace override, cached engine checkout
or public-registry fallback invalidates this acceptance.

In a fresh Foliostrate Actions checkout on its own commit, create the registry
configuration in a temporary file with mode 0600. It should contain the literal
environment placeholder, not a saved token:

```ini
@seventwo-studio:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}
```

Set `NODE_AUTH_TOKEN` only in the install step from that job's `GITHUB_TOKEN` and
set `PNPM_CONFIG_NPMRC_AUTH_FILE` to the trusted temporary user-auth file;
`NPM_CONFIG_USERCONFIG` is a supported fallback. Do not put this placeholder in
the project's `.npmrc`: pnpm 11.25.0 does not expand it there.
[pnpm's authentication documentation](https://pnpm.io/npmrc) explains that boundary.
Never echo resolved auth config or enable shell tracing.

Use the committed `pnpm@11.25.0` toolchain and frozen lockfile:

```sh
pnpm install --frozen-lockfile --store-dir "$acceptance_dir/store"
```

Create `acceptance_dir` with `mktemp -d` inside the fresh job's `RUNNER_TEMP`;
its store and the checkout's `node_modules` must not exist before installation.
Record manifest/lockfile hashes before and after and require no changes.
Require the exact dependency specifier and accepted registry integrity/tarball
in the committed lockfile; no editor override, local substitution, offline store,
checksum update or public fallback counts. Remove the temporary auth file on
every exit path. Do not require new developer PAT scopes.
[Frozen-install semantics](https://pnpm.io/cli/install) preserve the reviewed pin.

Validate each exported entry, CSS and TypeScript build, then run the real
Foliostrate editor build and browser interaction checks appropriate to the accepted
browser migration. Save/reopen must retain content, IDs, marks, references and
nesting. Exercise async loading and a missing/invalid WASM module failure with
retry. Confirm the installed dependency's exact name/version and integrity from
the lockfile. Store redacted evidence, not tokens.

Private visibility requires package metadata/UI evidence **and** grant inventory.
An unauthenticated 401 is insufficient. After positive installation, temporarily
remove the approved Foliostrate Read grant as a controlled acceptance step, run an
isolated install with the same repo's fresh job token and empty cache, require
denial, then restore exactly Read and require success again. Explicitly include
this temporary revoke/restore in the reviewed decision; if the publisher is still
inherited, verify Foliostrate has no other path to access. No unapproved repository
needs a grant for a negative test. Read capability must not be confused with a
write or Admin grant.

Require a redacted registry 401/403/404 for the exact package or tarball in the
denied job. An unrelated install/build failure does not establish denial. The
same Foliostrate principal is temporarily without Read; this procedure creates
no new principal or repository grant.

## Multi-platform package acceptance

ST-34 resolves the npm/private-access recovery. It does not close
[ST-106](https://linear.app/seventwo/issue/ST-106/verify-private-editor-packages-in-clean-consumer-hosts)
or establish acceptance of all editor platforms.

Coordinate installed assembly evidence with ST-48's
[reference integration acceptance](https://github.com/seventwo-studio/block-editor/blob/86fef181add1452bb7ffb6a5429a4f8dd0af7931/docs/reference-integration-acceptance.md)
in [draft PR #35](https://github.com/seventwo-studio/block-editor/pull/35).
Its Swift/AAR/TypeScript-WASM matrix requires all family contracts and actual
initialization. The immutable draft reference establishes the proposal's scope;
its CI/review and the package gates remain pending.

| Surface | Required separate proof |
| --- | --- |
| Swift/Apple | A versioned private SwiftPM distribution with exact revision, matching source provenance and reviewed read-only host access. A public Git dependency or local path cannot prove private package delivery. Build clean consumers for iOS, iPadOS, macOS, visionOS, watchOS and tvOS at OS 26; test local save/reopen and the platform-appropriate interface. Private Git source authentication is separate from npm Actions access and requires its own reviewed mechanism; no expanded PAT scope is implied. |
| Android | A versioned AAR/POM with Kotlin API, transitive dependencies, both `arm64-v8a` and `x86_64` JNI libraries, Swift runtime dependencies and documented toolchains. Install without source-project substitution, then execute on API 26 and current targets. GitHub Maven/Gradle packages inherit repository visibility and permissions; they cannot gain npm-style granular privacy on the public source repository. Use a reviewed private artifact host and a separately approved read mechanism. |
| Browser/WASM | A versioned wrapper plus the exact WASM artifact, checksum and supported ABI/protocol versions. The current npm inventory omits `.wasm`. Review whether to bundle the module or deliver it separately inside the same private boundary. Validate initialization, loading/failure/retry, CSP/asset serving, React input and save/reopen in Chromium, WebKit and Firefox after native acceptance. Downloading a wrapper that cannot initialize the engine is insufficient. |

[GitHub's permissions model](https://docs.github.com/en/packages/learn-github-packages/about-permissions-for-github-packages)
distinguishes granular npm access from repository-scoped Maven/Gradle access.
Any private Swift or Maven hosting/access choice beyond the npm recovery must be
recorded separately before provisioning. Package tests complement the engine,
reference-integration and actual input/accessibility gates; none replaces them.

## Rollback and completion evidence

On a failed candidate, stop publication and consumer upgrades. Keep consumers on
their last accepted exact private version; the exposed identity is not an approved
rollback target. Preserve failed-run logs and artifact checksums. Withdraw an
unaccepted replacement version only with exact deletion approval. For accidental
public exposure, stop access grants and publication, inventory evidence and return
for recovery review; do not claim revocation of prior downloads.

For an approved exposed-package removal, retain the namespace and 30-day restore
window as a conditional recovery option. Restoring would also restore the exposed
publication, so require an explicit decision and verify its resulting visibility.
Do not reuse the old name or automatically restore it when replacement delivery
fails. Access rollback means removing only the newly approved Foliostrate grant;
retain legitimate publisher/maintainer access and the fixed budget guard.

Attach the accepted decision, before/after visibility and access inventory,
exposed-publication treatment, package/source integrity, immutable release and
consumer CI references, fresh positive/negative installs, current budget evidence,
and unresolved multi-platform limits to ST-34. Leave its criteria unchecked until
their corresponding evidence exists. This document provides the recovery choices
and acceptance procedure; it records no executed recovery or approved decision.

Review-only implementation details and inactive publication/consumer lock
fixtures are in [private-delivery-review/README.md](private-delivery-review/README.md).
Their synthetic tests do not establish package privacy, real installation,
allowance or approval. No operative workflow, grant or registry change is enabled.
