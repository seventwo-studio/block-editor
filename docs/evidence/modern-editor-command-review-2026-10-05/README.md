# ST-120 command contract review evidence

[The command contract](../../modern-editor-command-contract.md) defines 18 local/collaborative scenario expectations and separates existing behavior from modern implementation obligations. The [original Swift log](reused-command-tests.log) records the unchanged-core reuse check:

`swift test --filter '(writingBatch|schemaRetainedPeerSupportsConversionShortcutAndMerge|v4RequiredUndoPersistsAndExplicitRedo)'`

All 11 selected Swift tests passed, including parameterized retained-peer conversion/shortcut/merge and both-author retained Undo recovery. They cover origin-preserving mixed deletion/move/duplicate, backward selection, overlap/composition rejection, conversion and explicit recovery. The [receipt](receipt.json) pins the production core hash set, contract/script-independent test input and original log hash. No new tests were written to mirror the proposed implementation.

Source review also checked current protocols 3–6, protocol-7 rejection fixtures, metadata/mark admission, typed collections, Apple commit/remote-hold/retarget boundaries and Compose/TypeScript explicit-version creation. Modern protocol 7, title/appearance, semantic-color marks, retained column routing and typing grouping are specifications awaiting ST-122; ST-140 independently reviews their fixtures. This evidence does not accept native focus/IME, physical devices, assistive technology, the browser integration lane or delivery packaging.
