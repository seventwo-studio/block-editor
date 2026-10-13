# Contextual interaction repairs

Finishing work for [ST-104](https://linear.app/seventwo/issue/ST-104) and
[ST-121](https://linear.app/seventwo/issue/ST-121), implemented at
`32ddbfa4210db64e81eb66a919ecd1e636aec8c4`. The React surface changes; the shared
Swift engine and actual WASM remain the delivered source and bytes recorded in
[receipt.json](receipt.json). The existing private registry version is unchanged.

| Reproduced behavior | Result after repair |
| --- | --- |
| Keyboard split preview continued showing 6999 after the peer committed 4000 | Preview ends on commit; UI presents 4000; original input focus stays; author Undo retains the peer resize |
| Escape during a slider drag left the preview active and could author it | Cancellation leaves the entire accepted save/history unchanged and restores the shared split |
| Cancelling accessible Insert lost the original text focus | The captured origin/caret is restored and the next typed character goes there |
| Escape left the Link dialog open | Dialog dismisses, original input focus returns, accepted content/history stay unchanged |

`candidate.json` records **36 passed** across Chromium, WebKit and Firefox, with
normal exit 0 and no skipped, flaky or unexpected cases. Each engine runs the
four new interaction checks alongside three existing integrated editor checks,
four preservation checks and the 55-document / 26-command typed consumer
contract. Source, demo and modern-test TypeScript checks pass. The JavaScript
artifact builds (`javascript-build.log`); it has not been published.

## Original failures and independent expectations

`original.json` and `reproduction.json` failed during the new test host's React
bootstrap. HTML served through Vite's filesystem route does not receive its index
transform; the pinned React development preamble is now explicit. No editor
assertion ran in those attempts.

`product-reproduction.json` then reproduces all four actual interaction failures
in Chromium against the original React source. `repaired.json` retains the first
repair's seven passing and five failing observations. One test action incorrectly
assumed End moves to the text end on macOS; it was corrected to ordinary arrow
navigation, with an explicit DOM caret check before opening the menu. Document
expectations were not changed or captured from the failing implementation.

`repaired-final.json` records eleven passing observations and the remaining
Firefox drag-preview failure. `firefox-drag-state.json` contains the actual event
sequence: Escape keydown/keyup restored 7000 and the accepted split stayed 7000,
but Firefox emitted input/change with 3217 **after pointerup**. The cancelled
gesture now suppresses that final native input through the release dispatch.
`firefox-drag-fixed.json` records the focused passing rerun before the complete
candidate. WebKit also requires the active gesture to receive Escape at the
window capture phase when native dragging does not focus its range input.

The test host is confined to `tests/helpers`; it uses the real React surface,
shared Swift/WASM session and browser input. Its peer seam supplies a different
author's checked commands. Failed runs retain original DOM, pixels, state/events
and traces under `.build/finishing/20261013/context`. Versioned original reports
and their SHA-256 hashes are retained here in [files.json](files.json).

## Reproduce and remaining scope

```sh
bun node_modules/typescript/bin/tsc -p tsconfig.modern-tests.json --noEmit
bunx playwright test --config playwright.swift.config.ts \
  tests/modern-context.swift.ts tests/modern-editor.swift.ts \
  tests/modern-preservation.swift.ts tests/modern-adapter.swift.ts \
  --workers=1 --global-timeout=240000
```

Fresh PR CI and review remain necessary. These checks do not complete the entire
44-scenario corpus, full native/rendered/assistive/touch acceptance, long-document
performance, modern relay process restart/recovery or final product acceptance.
Luca deferred physical-device and final-review availability; affected issues
remain open. Publishing repaired JavaScript would require a new version and its
own concrete delivery approval, rather than overwriting private 0.2.0.
