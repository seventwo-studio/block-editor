# Collaborative writing validation checkpoint

This experimental v3 session API supports atomic paragraph split/merge and selection replacement while preserving immutable text and formatting identities. Adoption requires the explicit archived epoch cutover described in [the protocol contract](collaborative-writing-v3.md).

## Completed evidence

On 2026-10-01, 34 focused Swift host tests passed. The integrated corpus contained 2,934 requests: 5 bridge, 1,972 structure, 665 recovery, 59 documents and 233 writing. Native Swift and actual Chromium, WebKit and Firefox produced byte-identical complete reports; each browser also passed its typed writing-session test. Independent source and literal-oracle reviews found no actionable defects.

Those executions used default `280545a8e211bc0235b929d27971deb2b3790108` with overlay tree `907b586fc1efbb2203b031153f053b94856f958f`. They are not executions of a later delivery commit. The full report SHA-256 is `bcade61965a96973ae67504f051df498ccc8cf59832054f723bf663f8dbe8eba`. The immutable tested WASM SHA-256 is `19919f54af7c6cf02e4d2d3fb70a0be74af73ffd53d97c97ec418bb46e1faa0f`; native bridge SHA-256 is `ba6cda2cd0dd3d6a456432e7cfcb06ef1faed9e61c48a447d54b564174456533`.

The delivery overlay was subsequently integrated onto `f97db3023e2ce79cca534e6ac6e3b869eec37224`, preserving accepted Apple controls, legacy author undo, loader tests and expanded recovery fixtures. Independent source review verified the 17 core/ABI/WASM/Package/CLI compilation inputs were unchanged. Prepared Kotlin harness tests cover typed split/format/position/reopen undo, composition queues and durable pending recovery; their source review is complete, while Kotlin compilation and Android execution remain pending.

## Reproduction and remaining gates

Run `swift test --filter 'writing|legacyStoppedAuthor|independent'`, then build the bridge and run `node scripts/run-native-compatibility.mjs .build/debug/editor-bridge test-results/compatibility/native.json` for the native report. Build WASM with `bun run build:wasm` and run `bun run test:wasm -- tests/runtime-compatibility.spec.ts tests/writing-runtime.swift.ts --workers=1`. Use `scripts/compare-runtime-reports.mjs` with one native report and one report for each runtime in a dedicated output directory. Android uses `RuntimeCompatibilityTest` for the raw corpus and `WritingSessionTest` for the three typed tests; qualify packaged JNI ABI and device API independently.

Current delivery-head CI/review, Kotlin compilation, actual Android writing tests and JNI runtime parity remain open. Swift Android library compilation alone does not establish these gates. Native input, IME, selection, accessibility, storage, room negotiation and consumer adoption remain separate host acceptance work. Whole ST-42/ST-97 completion is not implied by this draft.
