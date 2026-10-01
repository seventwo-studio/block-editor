# Native capacity reference workflow

When the local relay rejects a complete history at its 8,000,000-byte exchange limit, the Apple reference host retains local author history and offers export and synchronization retry. A failed local save retains the edit in memory and offers export and local-save retry.

## Reproduce

Use the installed OS27 iPhone Simulator and reserve its test session before running. Set `BLOCK_EDITOR_BRIDGE` to a qualified native `editor-bridge` executable and `CAPACITY_OUTPUT` to an owned evidence directory. Use an owned derived-data path:

```sh
bun scripts/test-apple-capacity.ts <simulator-UDID> <derived-data-path> --build
```

The build requires the installed Xcode SDK and `xcodegen`. After the initial build, omit `--build` to reuse products only when the exact Swift source and app/test product hashes still match. The harness requires 500 MiB free space, seeds a fresh task UUID/writer under the installed app container, and refreshes that container after XCTest reinstalls the app. It never resets unrelated drafts.

Four separate XCTest process phases exercise real authenticated HTTP413 rejection and export; app/relay termination and offline reopening with no token/request; an actual task-draft write failure, export and local-save retry; and a restarted relay followed by explicit synchronization retry. The request observer records every POST before reading its body. Retry must follow the armed cursor with a newly completed authenticated typed413 response. Offline phases require zero request starts. The driver checks exact accepted history, original actor, full8MB content, fresh-actor archive restoration and unchanged accepted server files. Task services stop in `finally`; logs, archives, result bundles and qualification remain in the evidence directory.

## Verified bounded evidence

[Machine-readable receipt](native-capacity-evidence/iphone-os27.json) records the tested source identity and independently audited results. All four actual OS27 iPhone tests pass without skips. Explicit retries are sequences9→10 and21→22; offline/failed-save have zero POST starts. Three complete archives retain their decoded histories, including the failed-save edit. Screenshots show the capacity limit, retained Unicode content and export/retry/share controls.

The tested source combines accepted Apple/legacy default `f97db302` with recovery PR41 head `734a80bf`, plus this follow-up. This draft depends on PR41. Its publication head and hosted CI are separate from that local qualification; publication does not relabel those results as fresh-head execution.

Prior failed Swift actor-isolation compilation and the successful prepare test followed by stale-container inspection failure remain preserved locally. The reviewed helpers use explicit main-actor isolation; the harness now re-resolves the task draft before inspection or blocking its write destination.

## Remaining acceptance

The failed-save status exposes a verbose NSError filesystem path and needs concise user-facing copy. Final macOS restart/retry verification, minimum runtimes, other Apple families, accessibility, physical-device/system input, completed system sharing, current-head hosted CI/review and consumer/private-distribution remain open. Share-control visibility does not prove a completed system share. ST96 remains In Progress.
