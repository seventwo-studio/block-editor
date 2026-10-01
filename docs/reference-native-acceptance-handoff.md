# Native reference acceptance handoff — 2026-10-01

[ST-48](https://linear.app/seventwo/issue/ST-48/verify-local-and-collaborative-reference-integrations)
remains In Progress. This supplements the
[acceptance contract](reference-integration-acceptance.md) delivered in
[PR #35](https://github.com/seventwo-studio/block-editor/pull/35).
ST-48 independently reviewed producer source, raw test logs, preserved artifacts
and proof JSON. It did not rerun the native tests.

## Android authoring: scoped findings resolved

ST-46 owns [draft PR #38](https://github.com/seventwo-studio/block-editor/pull/38);
ST-103 produced the native evidence. Delivery head at this handoff is
`33f225ebe0768ed3c820a58adaec10d66d3a9e93`, integrated tree
`9054e1c79a7854ca626ff6ea19dbc5b0018848c0`. All 12 intended paths and preservation
of the 13 accepted Apple/legacy files were checked against default
`f97db3023e2ce79cca534e6ac6e3b869eec37224`.

API35 ARM64 V7 passes in three separate instrumentation invocations:

| Invocation | Result | Seconds |
| --- | --- | ---: |
| Original Compose/input/authoring cases | 15/15 | 20.883 |
| Retained Bold/Apply reparent and read-only Bold | 3/3 | 4.741 |
| Separate retained read-only Apply | 1/1 | 2.002 |

Both reparent cases invoke the actual retained rendered callback in the receive
UI turn before Compose detachment and again after idle. Original, replacement
and full saved history remain unchanged in both phases. After read-only
recomposition removes the toolbar, retained Bold and Apply preserve full history.
All four proofs have run ID `5ccb252b-420f-4f51-bd2c-244f60d8dbe4`.

Independent artifact checks pin:

- V7 feature tree: `2f2e8ed1ccb6c4e400195a9cea89a18b83788152`.
- Preserved and installed APK SHA-256:
  `c4ece096061405bb0a54ef7513f5d172515a73984fbb624a8e647df5285253e9`.
- Tested three-file regression patch SHA-256:
  `ad88d1eb1e08ad898d07425b4a08d1ee399dd0a9947c4a8a6f7fccc013ef551d`.
- Five production and three regression-source hashes match the frozen manifests;
  packaged JNI hashes match the tested environment.

V5's retained callbacks retargeted an old-path replacement; V6 fixed reparenting
but its retained Bold callback bypassed a later read-only transition. V7 reads
current permission through `rememberUpdatedState` in the shared action guard.
Failing V5/V6 receipts are preserved. These findings are resolved in the tested
scope. The JNI baseline remains `e787146c432e649e71a1a6423fe4a24c55e21f5c`;
this does not establish current-default/v3 engine, full IME/accessibility, other
Android architectures or private package acceptance. Fresh published-head checks
and root's merge preflight remain required.

## iPhone capacity: four-phase workflow verified

ST-96 owns capacity source/delivery. Four OS27 iPhone XCTest phases pass with
zero skips: prepare (19.136 s), offline reopen (8.775 s), failed local save/export/
retry (15.064 s), and transport retry after relay restart (18.207 s).

The independently decoded receipt records zero POST starts in offline and
failed-save phases. Explicit retries produce additional authenticated completed
HTTP413 responses with the typed capacity error: sequence 9→10 and 21→22.
Accepted-server file bytes remain unchanged in all phases. Three exported
archives have verified byte counts/hashes and retain the full 8,000,000-byte
extension blob. Failed-save and retry archives contain identical 18-change
history. The completed, source-reviewed driver asserts retention of the local
failed-save edit and archive restoration under fresh actor identities.

Frozen follow-up identities:

- Complete patch SHA-256:
  `f9fd50893dd0f9996d379eb00bfdb3cf760d3ae3212075b1d4dc19cf082ea6ce`.
- Exact applied source tree: `da3610067f6cb6569ac6a6868cfaeebbbe4fd3b7`.
- Harness SHA-256:
  `0849eaab2d6db52dcd26f741f543dcf96e8f4dadfd7a1205dea78d7015f3ae7a`.
- XCTest source SHA-256:
  `31800c54b19fb76d5638dba124dfeb9cad0ffa62fb3b27747993286c8f49447f`.
- Campaign receipt SHA-256:
  `1f2866dcdb960cbbb8bb75b2f840cc9aaa478bf0126dab56c86bfa129acaeffd`.

Prior actor-isolation build failure, migrated-container inspection failure and
incomplete export are preserved. The corrected harness re-resolves the app
container and checks the task-owned draft UUID/actor before storage blocking or
inspection. Passive screenshot review confirms retained content and visible
retry/export/share controls; the raw NSError text exposes a long filesystem
path. Wider layout/accessibility and completed system sharing remain unaccepted.
This is one installed OS27 iPhone reference workflow, not every Apple family or
minimum supported runtime.

## Remaining delivery and acceptance owners

ST-39/ST-103 own [draft PR #41](https://github.com/seventwo-studio/block-editor/pull/41).
Diagnostic head `979a572a8fa76d5a46d77e2fb624d711a9b8a230` preserves all nine
frozen recovery files and accepted Apple/legacy files. Its original native Paste
predicate remains unchanged. CI run
[36876819791](https://github.com/seventwo-studio/block-editor/actions/runs/36876819791)
was sampled with an API35 x86_64 Gradle dependency-resolution failure before
native test execution. Earlier API26/parity failures belong to head `734a80b`;
neither historical checks nor older runtime artifacts accept a newer head.

ST-105 owns remaining all-platform relay acceptance. ST-34 still needs the human
private-route recovery decision; ST-106 needs fresh clean-host native/browser
private installs. Numeric budgets and full input/accessibility/assets gates
remain open. Partial merged increments and these scoped passes do not close ST-48.

Raw logs, proof JSON, screenshots, archives and APKs remain in issue-local review
storage and producer evidence directories. Only this bounded handoff is published;
artifact hashes above let the next owner match retained evidence without moving
large binaries or sensitive raw diagnostics into Git.
