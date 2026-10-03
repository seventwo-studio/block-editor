# Current-editor baseline evidence

4 October 2026 (Europe/Amsterdam), [ST-116](https://linear.app/seventwo/issue/ST-116). Source `01a0e35cceace2e6cd0ae2366621caf305bfd169`, tree `98e79d53caa0e178d281826733e7e62d6fd06451`; assessment adds documentation/captures without changing product source. Environment: arm64 macOS 27.0.1 (26A434), Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), Bun 1.4.2, Playwright 1.63.0. Runtime versions are in `browser-captures.json`.

| Check | Result and retained log |
| --- | --- |
| `swift test --scratch-path /private/tmp/block-editor-modern-assessment-build` | Build passed, 273 core + 76 Apple component + 8 local-demo tests passed. `swift-test.log`. Native component checks do not establish actual UI/device acceptance. |
| `bun run test` | 110 passed, 0 failed, 278 assertions. `typescript-test.log`. |
| `bun run typecheck` | Passed. `typecheck.log`. |
| `bun run demo:typecheck` | Passed. `demo-typecheck.log`. |
| `bunx playwright test tests/authoring.spec.ts tests/inline.spec.ts tests/images.spec.ts` | 44 passed in Chromium/WebKit. `browser-tests.log`. Selected existing host restrictions, paste, formatting/input and image cases; not full browser acceptance. |

Initial sandbox attempts could not access Swift caches/start the local browser server. The successful authorized runs above resolved those environment restrictions without product changes; the logs here belong to completed runs.

The eight PNGs show the unchanged React/TypeScript demo at 1440×1000 and 390×844, in Meadow/Midnight appearance and after typing. The two WebM recordings cover theme switching, paragraph typing and viewport change in the same session. No WASM/native adapter, physical touch, assistive technology or performance acceptance is claimed. The five-block demo is a representative existing canvas, not the 1,000-block performance fixture.

Reproduce from the stated source with existing installed dependencies: run `bun run demo:dev --port 42781 --strictPort`, then `bun docs/evidence/modern-editor-assessment-2026-10-04/capture.mjs`. The capture helper uses the existing local demo, writes into this evidence directory and does not add an editor capability. Archive these results before reproducing, since the named capture outputs are replaced. The helper assigns stable recording names after the browser closes; original results were captured by its equivalent temporary helper before that naming adjustment.

`manifest.json` records SHA256/size of each retained evidence file. The baseline capability/gap mapping and current native-capture blocker are in [the assessment](../../modern-editor-assessment.md). Missing Mac Computer Use and physical/assistive-technology evidence remain explicit; historical foundation captures retain their original source/artifact qualifications.
