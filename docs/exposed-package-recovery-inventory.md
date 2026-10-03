# Exposed package recovery inventory

Read-only refresh: 4 October 2026 (Europe/Amsterdam). Owner: [ST-168](https://linear.app/seventwo/issue/ST-168). The [earlier proposal](private-package-recovery.md) and [inactive review fixtures](private-delivery-review/README.md) retain their original dates and observations.

| Item | Verified result / boundary |
| --- | --- |
| Source | `seventwo-studio/block-editor` is public; GitHub reports default `main`. Inspected source `01a0e35cceace2e6cd0ae2366621caf305bfd169`, tree `98e79d53caa0e178d281826733e7e62d6fd06451`. Earlier default-branch observations are historical. |
| Manifest | `@seventwo-studio/block-editor@0.1.0`, GitHub npm registry, source repository link; declared package files omit compiled WASM. This is source intent, not every remote version. |
| Workflow | `.github/workflows/package.yml` is candidate-only validation with contents-read and no publication/package-write step. Source retirement is verified; remote recovery is not. |
| Historical publication | [Run 36475566396](https://github.com/seventwo-studio/block-editor/actions/runs/36475566396) still exists, completed/failure, dispatch source `b111e23374444c04df847c66a6f6c8e8cd4918f7`. Earlier proposal retains publication-success/privacy-failure observations. |
| Current package GET | HTTP 403 requires `read:packages`. Existing credential cannot read metadata. This does not establish absence, visibility, version IDs, grants, downloads or privacy. No credential expansion occurred. |
| UI/consumers | Earlier settings showed Public; that is historical. Computer Use is unavailable for permitted current Mac UI inspection. No new approved consumers or grants are inferred from old Foliostrate observations. |
| Budget | Required $0 Packages cap and Stop usage unchanged. Current headroom unavailable; no charge, provisioning or publication. |

## Exact recovery proposal

Recommend removal of the exposed organization npm identity `block-editor` only after authenticated inventory enumerates every package/version ID, downloads, approved consumer dependencies, published artifact checksums and publisher source/run. Preserve restricted evidence first. Additional versions require exact enumerated approval; the local `0.1.0` manifest is not deletion authority for unenumerated versions.

Luca's approval must name the exposed package, each selected version, preserved evidence location and method. It must not silently include source-repository deletion, replacement publication, access grants or credential expansion. If retaining the public identity is chosen, record the explicit exposure decision and its acceptance against ST-168 before closure.

Before approved execution, verify current deletion/restoration rules in GitHub's authoritative documentation, download limits and namespace conditions. The earlier proposal's conditional restore window is historical guidance, not a current guarantee. After execution verify authoritative state/exposed path and retained approved internal access where applicable. Anonymous npm denial alone does not establish privacy; prior downloads cannot be recalled.

The proposed private publisher/replacement in the earlier document is deferred to ST-34 after ST-143, ST-104 and ST-168. No replacement repository/service, publication, temporary grant changes or consumer implementation is authorized by this inventory. Private Swift/AAR/TypeScript-WASM mechanisms still need exact reviewed decisions and acceptance.

## Preservation and rollback

Retain metadata/version IDs, checksums, source/run, visibility/access inventory and approved pins in restricted storage without credentials or signed URLs. Preserve current source and the historical Git archive. Failed recovery stops at ST-168; automatic delete retry, name reuse, public replacement or restoration is not authorized. Conditional restoration requires approval because it may restore exposure.

ST-168 remains In Progress pending current inventory through an authorized read channel and Luca's exact recovery approval. ST-34 retains native dependencies on recovery plus both acceptance stages. This document records preparation, not executed recovery or private delivery.
