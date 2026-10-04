# Exposed package recovery inventory

Read-only refresh: 4 October 2026 (Europe/Amsterdam). Owner: [ST-168](https://linear.app/seventwo/issue/ST-168). The [earlier proposal](private-package-recovery.md) and [inactive review fixtures](private-delivery-review/README.md) retain their original dates and observations.

| Item | Verified result / boundary |
| --- | --- |
| Source | `seventwo-studio/block-editor` is public; GitHub reports default `main`. Inspected source `01a0e35cceace2e6cd0ae2366621caf305bfd169`, tree `98e79d53caa0e178d281826733e7e62d6fd06451`. Earlier default-branch observations are historical. |
| Manifest | `@seventwo-studio/block-editor@0.1.0`, GitHub npm registry, source repository link; declared package files omit compiled WASM. This is source intent, not every remote version. |
| Workflow | `.github/workflows/package.yml` is candidate-only validation with contents-read and no publication/package-write step. Source retirement is verified; remote recovery is not. |
| Historical publication | [Run 36475566396](https://github.com/seventwo-studio/block-editor/actions/runs/36475566396) still exists, completed/failure, dispatch source `b111e23374444c04df847c66a6f6c8e8cd4918f7`. Earlier proposal retains publication-success/privacy-failure observations. |
| Current package GET | HTTP 403 requires `read:packages`. Existing credential cannot read metadata. This does not establish absence, visibility, version IDs, grants, downloads or privacy. No credential expansion occurred. |
| UI/consumers | The authenticated Browser refresh below supersedes earlier package-settings observations. No new approved consumers or grants are inferred from old Foliostrate observations. |
| Budget | Required $0 Packages cap and Stop usage unchanged. Current headroom unavailable; no charge, provisioning or publication. |

## Authenticated Browser inventory

4 October 2026, 09:06 Europe/Amsterdam: authenticated Browser settings verify npm identity `@seventwo-studio/block-editor` is Public. The complete versions view lists one active version, `0.1.0`, version ID `1307159394`, zero deleted versions and zero reported downloads. A second pre-approval versions read confirmed the same inventory. The source remains `seventwo-studio/block-editor`; Actions access lists only that source repository as Admin, source-access inheritance is enabled, direct members display zero and no explicit Codespaces repositories are listed. This is observed access, not authorization for new consumers.

The exact publisher log from run `36475566396`, source `b111e23374444c04df847c66a6f6c8e8cd4918f7`, records successful `0.1.0` publication followed by a failed private-visibility check. It reports SHA1 `a7d88dca56a6ed35b6d31892c4d574d56f6ac781` and integrity `sha512-64sGmtiDeTJuhyeEBm+BqUiOptb1mdrmm8/oqLDnNmzW9l8suK98rbbkb00oFWpf+0ze4niCQ0n+OUXIvdxoGA==`. These are historical publisher checksums, not freshly verified registry bytes; the registry tarball was not downloaded and the run retains no downloadable workflow artifact.

Restricted UI inventory, settings, version identity, confirmation preview, publisher-log excerpts, source archive and checksummed recovery plan are retained locally in `/private/tmp/block-editor-package-recovery-2026-10-04`. The source archive SHA256 is `4514fb523a01a2ece761d30dad8615a8809bb6fae44e4a562dd0dd546938e4e1`. These local receipts are not uploaded durable artifacts. No credentials or signed URLs are included. Browser supplied the current inventory without changing token permissions; CLI package metadata access still returns 403.

## Approved recovery method

Luca approved **Delete this package** for organization npm identity `block-editor`, removing its sole enumerated version `0.1.0` / ID `1307159394`. The complete version inventory was rechecked immediately before submission. An additional version or changed target would have stopped execution and required exact amended approval. The source repository is preserved; no replacement publication, grants, token expansion, spending or consumer work is included.

Luca's approval must name the exposed package, each selected version, preserved evidence location and method. It must not silently include source-repository deletion, replacement publication, access grants or credential expansion. If retaining the public identity is chosen, record the explicit exposure decision and its acceptance against ST-168 before closure.

Current [GitHub visibility documentation](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility) states that a public package cannot be made private again. The UI offers a Private radio option; selecting it without submission is not evidence that the backend would permit that transition. The proposed removal avoids relying on that unverified path. [Deletion/restoration documentation](https://docs.github.com/en/packages/learn-github-packages/deleting-and-restoring-a-package) allows public-package removal below its download threshold and conditional restoration within 30 days if the namespace remains unused. Restoration is not guaranteed and needs separate approval because it may restore exposure. After approved removal, verify disappearance from current package listing/detail and deleted-package inventory where available. Removal does not establish a retained private package or approved internal installation; anonymous npm denial alone does not prove privacy.

The proposed private publisher/replacement in the earlier document is deferred to ST-34 after ST-143, ST-104 and ST-168. No replacement repository/service, publication, temporary grant changes or consumer implementation is authorized by this inventory. Private Swift/AAR/TypeScript-WASM mechanisms still need exact reviewed decisions and acceptance.

## Approved removal and verification

Luca approved the exact enumerated deletion with **“deletion approved”**. The complete versions view was rechecked immediately before submission: one active `0.1.0` / ID `1307159394`, zero deleted versions and zero reported downloads. Authenticated Browser submitted **Delete this package** for the organization npm identity `block-editor` only.

GitHub redirected to the source repository's empty package list. The original package detail URL then returned the GitHub 404 page, and the organization's **Deleted packages** inventory listed `block-editor`, deleted moments earlier. The source repository remains present and public with default `main`. This verifies removal of the exposed publication; it does not establish a retained private package or replacement installation.

The restricted local recovery folder retains the human approval, immediate pre-submit inventory, post-submit page, 404, deleted-package inventory and screenshots. Verified plan SHA256: `7f2749c07907b7447999b7dbdd2332ea51127c31a37be9a35cad4de3c1e944ee`; deleted-inventory text SHA256: `70751707c16973c9c309ef23ca12c167cf3744da2fef5b40328ac36cc4566fb9`. Registry tarball preservation retains its earlier qualification. No other package, repository, grant, credential, spending or consumer action was performed. No replacement was published.

## Preservation and rollback

Retain metadata/version IDs, checksums, source/run, visibility/access inventory and approved pins in restricted storage without credentials or signed URLs. Preserve current source and the historical Git archive. Failed recovery stops at ST-168; automatic delete retry, name reuse, public replacement or restoration is not authorized. Conditional restoration requires approval because it may restore exposure.

ST-168's enumerated exposed-package recovery is verified and linked to ST-34. ST-34 retains both native and browser acceptance prerequisites before any separately approved private publication. The $0 Packages cap and Stop usage remain unchanged. Conditional restoration remains separately gated because it could restore the exposure.
