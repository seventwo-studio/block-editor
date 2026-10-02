# ST-34 implementation preparation

Recovery is waiting for the exact reviewed human decision. These files are
review-only fixtures under documentation and are excluded from the npm files list. They do not enable a workflow,
publish, provision a repository, alter grants, delete a package or change billing.

The existing proposal remains at
`/Users/luca/.codex/worktrees/private-delivery-proposal/block-editor/docs/private-package-recovery.md`.
The isolated proposal checkout is assigned to ST-34. Preserve the primary
historical `codex/apple-input` checkout.

## Refreshed inventory on 1 October 2026

| Item | Verified result |
| --- | --- |
| Engine source | `seventwo-studio/block-editor` is public. Default branch is `codex/initial-extract`, not `main`. Current default SHA `e7d616a0262eac4c368fdcf83f18890b5a83e5ac`, tree `1d23cc69ff5c157ab952778d35f3394c5227eefa`; GitHub reports Verified. This observation does not establish fresh package acceptance or release approval. |
| Existing publisher workflow | [Run 36475566396](https://github.com/seventwo-studio/block-editor/actions/runs/36475566396), source `b111e23374444c04df847c66a6f6c8e8cd4918f7`: local package check passed, prepublication check passed, publication passed, final privacy check failed. |
| Exposed-package inventory | Current CLI package metadata request returns 403: existing credential lacks `read:packages`. Version IDs, current grants, downloads and current visibility were not refreshed. Preserve earlier authenticated UI evidence as earlier evidence. No scope expansion. |
| Proposed publisher | Authenticated REST GET returns 404. This means absent or inaccessible; it does not prove name availability. No repository created. |
| Foliostrate | Private, default `main`, current SHA `92b4755ae242efe5d684f1faba4387b5788f4317`. `packageManager` is `pnpm@11.25.0`, with `pnpm-lock.yaml` format `9.0`. No editor dependency appears in the current root manifest. |
| Foliostrate CI | Uses Node 24, pnpm 11.25.0, frozen install; no package read permission/auth configuration. Typecheck, tests, API/dashboard/portal builds and Chromium Playwright exist. WebKit/Firefox package acceptance remains separate. |
| Native dependencies | ST-34 blocks ST-106 and ST-48. ST-106 is also blocked by ST-39, ST-93 and ST-94. npm delivery alone cannot close ST-106. |
| Local capacity | About 1.1 GiB free at observation. No dependency install or host/Android/WASM build performed here. |

Live Linear issue and discussion were read. ST-34 has no reviewed recovery
mechanism; its remaining criteria are unchecked. The proposed identity and
publisher below remain recommendations.

## Required reviewed decision

Record the exact proposal revision and acceptance in ST-34 and the existing
confirmed decision record before recovery implementation. The decision must
select:

- Private `seventwo-studio/block-editor-internal-packages` publisher and replacement
  `@seventwo-studio/block-editor-internal@0.1.0`, or a reviewed alternative.
- Publisher Actions Admin and Foliostrate Actions Read only; existing approved
  human maintainers; no public source Actions access or other consumers.
- The unchanged $0 Packages cap with Stop usage. Refresh budget controls and
  included storage/transfer immediately before execution; unknown headroom stops
  publication. No paid overage or credential expansion.
- Exact treatment of exposed `@seventwo-studio/block-editor@0.1.0`: preserve/retire
  with explicitly accepted residual exposure, or approve exact removal after
  authenticated inventory and restricted evidence preservation. New versions
  found during inventory require exact scope review. No deletion is implied.
- The temporary Foliostrate Read grant removal, denied clean install, exact Read
  restoration and repeated successful clean install as controlled acceptance.

Fixtures and a documentation merge cannot establish that decision. Human approval
of the recovery mechanism also does not establish fresh CI/review, package
privacy, budget availability, platform compatibility or consumer acceptance.

PR #64 also prepares retirement of the public source workflow's publication
path: `.github/workflows/package.yml` becomes manual candidate validation with
only `contents: read`, the existing version/type/test/build/tarball checks and
no registry publication or spending checkbox. This remains a source candidate
until reviewed delivery; historical package evidence and the current exposed
publication are unchanged. The recovery decision and private-host execution
steps below still require exact approval.

## Concrete change set after approval

1. Retire the old source publication workflow through a reviewed source PR. Remove
   its registry write capability and the input implying additional spending can
   be accepted by a dispatch checkbox. Public source CI continues to verify
   candidates without private registry credentials. Do not dispatch the current
   old-identity workflow.
2. Provision only the approved private publisher after repository/maintainer/name
   verification. Use a manually dispatched reviewed default-branch workflow and
   existing job token with `contents: read` and `packages: write`. Fetch the public
   source by approved full SHA, validate the Git tree, and require current
   GitHub-Verified delivery plus successful fresh checks and resolved reviews.
   Never fetch a mutable branch for publication.
3. Transform only the candidate manifest into the selected replacement name.
   Its `repository.url` points to the private publisher so npm inheritance cannot
   associate the artifact with the public source. Retain public source SHA/tree
   in explicit provenance. Replace hard-coded package imports in the candidate
   tarball checker using the actual manifest name (for example
   `JSON.stringify(manifest.name + '/react')`), including CSS and Swift exports.
   Validate every export, exact file inventory, packed/unpacked sizes and SHA-512
   integrity. Review the compatible WASM delivery contract before claiming a
   runnable engine package; the existing wrapper tarball omits the module.
4. Add private publisher/package checks before any publish. Only the verified
   private publisher may use a reviewed first-publication 404 path. 401/403/429,
   malformed metadata and other unknown responses stop delivery. Existing
   package metadata must match the exact name, private visibility and publisher
   association. Verify private visibility after creation and before consumer
   grants; stop on exposure without automatic deletion or public fallback.
5. Apply and verify only the approved access inventory. Package metadata alone
   does not establish Actions Read rather than Write/Admin. Observe grant state
   through authenticated package settings; do not test write capability by
   attempting a publication. No private signing-key reads, personal publisher
   token or cross-repository registry credential.
6. Consumer owner updates imports, root manifest and committed lockfile using the
   published exact registry version, integrity and tarball. No Foliostrate code
   changes are assigned to this ST-34 task. Coordinate the proposed consumer
   changes with the owner. Preserve existing native Linear dependencies.

## Clean Foliostrate Actions procedure

Use a fresh trusted Foliostrate checkout on an approved immutable SHA. Job
permissions are exactly `contents: read` and `packages: read`. No
`pull_request_target`, untrusted fork code, shared caches or downloaded engine
checkout is permitted for this acceptance run.

Pin pnpm to the current reviewed `11.25.0` and Node to the consumer's reviewed
Node 24 runtime. Before installing, parse the committed `pnpm-lock.yaml` with the
consumer's reviewed YAML parser and run the lock guard against the accepted
registry release record. Require exact version, SHA-512 integrity and an explicit
GitHub-registry tarball URL. If the generated lockfile omits a tarball URL, review
and commit that resolution representation before frozen installation; do not
invent metadata or weaken the origin check.

In an isolated job, create a fresh temporary directory and a mode-0600 user auth
file outside the checkout. Store the literal placeholder, not the token:

```ini
@seventwo-studio:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}
```

Use `PNPM_CONFIG_NPMRC_AUTH_FILE` pointing to that trusted temporary file;
`NPM_CONFIG_USERCONFIG` is pnpm's supported fallback. Do not put the placeholder
in the project `.npmrc`: pnpm 11.25.0 rejects expansion there. Bind
`NODE_AUTH_TOKEN` to the consumer's own ephemeral `GITHUB_TOKEN` only during the
install. Review project registry configuration/overrides before exposing it to
the token. Never print the resolved config or enable shell tracing.

The reviewed install command is:

```sh
pnpm install --frozen-lockfile --store-dir "$acceptance_dir/store"
```

`acceptance_dir` is created by `mktemp -d` inside `RUNNER_TEMP` in that fresh job.
No `node_modules` or store exists before the command. Cleanup removes the auth
file on every exit path; do not upload auth/cache files as artifacts. Record the
manifest/lockfile SHA-256 before and after and require no changes. No `--offline`,
`--prefer-offline`, `--fix-lockfile`, `--update-checksums`, `file:`, `link:`,
workspace package or editor override counts as registry acceptance.

Then resolve every exported module, CSS and TypeScript surface; inspect the
installed manifest and its actual path inside this fresh store. Compare it to
the exact accepted registry version/integrity. Run the consumer's real
typecheck/tests/builds and reference input/persistence/loading/failure/retry
workflows on Chromium, WebKit and Firefox as applicable. A model import or React
server rendering alone does not prove the compatible WASM artifact initializes.

Private-access acceptance has three separate fresh jobs:

1. Foliostrate has exactly Read; metadata and access inventory agree; clean
   frozen install and consumer checks succeed.
2. After the approved temporary Read removal, verify no inherited/other access
   remains. The same consumer's fresh token and new empty store must be denied
   by the private registry for the exact metadata/tarball. Capture the redacted
   401/403/404 response for that identity; an unrelated install/build failure is
   insufficient negative evidence. Do not use an anonymous 401 as privacy proof.
3. Restore exactly Read, re-inventory access and repeat a clean successful
   install. Save immutable CI URLs and exact source/publisher/consumer SHAs.

No jobs or grant mutations have been executed by this preparation.

## Fixture verification and limits

Run using an existing Node runtime:

```sh
node --test release-guards.test.mjs
```

`release-guards.mjs` takes already parsed, non-secret JSON evidence. It performs
no I/O or mutations. Its tests cover private/public/internal boundaries,
unauthorized/unknown metadata responses, explicit first-publication handling,
immutable source identity, exact version/integrity, peer-suffixed pnpm
resolution, local/public fallbacks, exposed identity, overrides and installed
manifest mismatch. All 27 cases passed on 1 October 2026 using the bundled Node
runtime. Test fixtures use synthetic SHAs/digests; they are not release records.

These guards do not authenticate human approval, attest the truth/freshness of
supplied metadata, measure allowance or prove the physical package download.
Wire them into the reviewed publisher/consumer workflows only after approval;
fresh authenticated observations and actual install runs remain mandatory.

Swift private source/binary distribution, AAR/POM coordinates and both JNI ABIs,
and the exact TypeScript-compatible WASM artifact remain unselected. ST-48 owns
the [assembly acceptance record](https://github.com/seventwo-studio/block-editor/blob/86fef181add1452bb7ffb6a5429a4f8dd0af7931/docs/reference-integration-acceptance.md)
in [draft PR #35](https://github.com/seventwo-studio/block-editor/pull/35).
Its review/CI and package acceptance remain pending. ST-106 cannot advance on npm
wrapper checks alone.

References: [GitHub Actions package visibility and grants](https://docs.github.com/en/packages/managing-github-packages-using-github-actions-workflows/publishing-and-installing-a-package-with-github-actions),
[GitHub npm authentication](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-npm-registry),
[Packages billing](https://docs.github.com/en/billing/concepts/product-billing/github-packages),
[pnpm frozen install](https://pnpm.io/cli/install),
[pnpm trusted auth configuration](https://pnpm.io/npmrc).
