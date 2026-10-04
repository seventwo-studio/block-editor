# Modern editor typography, surfaces and appearance

Design contract for [ST-119](https://linear.app/seventwo/issue/ST-119), reviewed 5 October 2026. The editor presents a continuous document with a quiet reading surface, clear hierarchy and contextual controls near the selection. Use the [platform contract](modern-editor-compatibility.md), [approved scope and reuse map](modern-editor-reuse-and-sizing.md) and the existing annotated references: 04's document rhythm, 22's selected formatting cues and 30's optional appearance settings. Decorative covers and additional editing capabilities are outside this contract.

The [interactive visual study](design/modern-editor-visual-preview.html) and [token source](design/modern-editor-tokens.json) define a concrete reference for native implementation. The study renders the existing Apple demo's `rich-blocks.json` unchanged for its table, expanded toggle and nested list. Long prose, illustration, file appearance, wide table and state samples are authored design content. It does not run the shared editor. Review controls above the document belong to this study, not the product canvas.

## Typography and readable width

Use platform system fonts for the sans, serif and monospace choices. Store preset names in the document; resolve fonts locally. Avoid downloading a typeface or depending on a particular font's presence. Document typography may be larger than surrounding app chrome.

| Role | Reference value | Native behavior |
| --- | --- | --- |
| Body | Default 17; small 15; large 20; line height 1.65 | Translate to scalable native text metrics; respect system text enlargement |
| Document title | 2.1 times body; weight 700; line height 1.25 | Direct editable title shares the document column; long titles wrap |
| Section / subsection | 1.55 / 1.2 times body; weight 650; line height 1.25 | Preserve semantic heading levels for outline and assistive navigation |
| Captions / secondary text | 0.88 times body, with readable muted ink | Never use faint placeholder or caption text to convey required meaning |
| Menus / host chrome | Native menu/control font; reference 14–15 | Follow host conventions rather than scaling every control with the document font |
| Code | Native monospace; reference 0.9 times body | Wrap inline code; scope long code/table scrolling to the block |

The six desktop comparison captures evaluate 680, 720 and 760 CSS px at both 16 and 17 CSS px body text. In the first sample paragraph, the first complete line contains 86 characters at 680/17, 95 at 720/17 and 102 at 760/16. These are measurements of this text and font, not universal line-length guarantees. Visual review favors **680/17 as the writing default**; 720 and 760 remain comfortable/generous choices for mixed documents. 16 remains a comparison, not an additional persisted preset. A 960 reference width accommodates two columns and wide content. Do not treat any width as a fixed minimum viewport or any CSS value as a mandatory native font size.

Constrain ordinary text to the chosen reading width and available host width. Wide media/table blocks can use the host's wider available document region; body paragraphs keep their measure. Media fits its container and maintains aspect ratio. A table preserves cell content and uses a separately focusable horizontal scroll region when necessary; the whole document must not scroll sideways. Layouts at 390 CSS px demonstrate both behaviors. Font size and viewport scaling must trigger remeasurement.

## Rhythm, gutters and tools

Spacing follows 4, 8, 12, 16, 24, 32, 48 and 64 reference units. Paragraphs separate by 16; section headings have 32 before and 16 after; subheadings use 24/12. Nested lists retain their existing hierarchy and modest indentation. Toggle children use a visible rule and disclosure control, rather than a card per paragraph. Dividers separate sections; they are decorative, not the only boundary of an actionable control.

Reserve a 44 reference-unit gutter for block actions. Reveal tools on pointer hover, selection or keyboard focus, and provide an explicit touch/assistive action without requiring hover. The narrow study reserves 52 on the leading side for the gutter plus inset and 20 on the trailing side. Direction-aware native layouts mirror the gutter while preserving logical document order. Controls target at least 44 reference units in this study; native implementations use their platform's appropriate touch, focus or spatial target metrics.

Contextual formatting sits near the selection. Block actions use a native popover/menu; the reference has a 288 maximum width, 12 radius and 8 inset, and shrinks to available width. When the anchor would be obscured by keyboard, zoom or the viewport edge, the host relocates the tools while retaining the selection. Accessibility actions expose the same commands. The visual study demonstrates appearance only; ST-120 specifies cancellation/focus, and ST-121 validates the working interactions.

## Color roles and state cues

The token JSON provides explicit light/dark values for canvas, neutral surface, raised tools, primary/muted text, decorative line, actionable border, focus, selected text/block fill and accent. The semantic palette is neutral, green, blue, purple, amber and red with separate ink/fill values. Shared documents store semantic names, not appearance-specific hex colors. Rendering and editing state colors remain host presentation. The error/warning roles use the corresponding red/amber palette with an explicit status label.

| State | Visual and accessible cue |
| --- | --- |
| Default | Readable label or icon; visible border when needed to identify the control |
| Hover | Surface change; pointer target remains readable; no information available only on hover |
| Focus | 3-unit outline with separation from its background; native keyboard/spatial focus treatment |
| Selected format | Checkmark, accessible pressed/checked state and outline alongside accent fill |
| Selected block/range | Selection fill plus edge/handle; distinguish block selection from text selection |
| Disabled | Unavailable state and contextual reason; retain readable label, not opacity alone |
| Loading | Explicit loading label/status; preserve block space; respect reduced motion |
| Error / warning | Symbol and concrete label, with recovery action when supported; color supplements the message |
| Link | Underline and semantic link role; color is supplementary |

Use at least 4.5:1 for normal text and 3:1 for meaningful authored control/state cues against adjacent backgrounds, following [WCAG text contrast](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html) and [non-text contrast](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html). The capture script checks underlying sRGB values without rounding before comparison. It covers normal/muted text on neutral and selection surfaces, all six semantic inks on every semantic fill and the focus/control-border roles. These checks are token evidence, not a complete accessibility audit. Decorative lines may be subtler because they do not identify a control. User-specified high contrast and system accessibility presentation take precedence over these reference fills.

Dark appearance has its own ink/fill pairs rather than inverting the light palette. Review dark body text, media captions, table header/cells, menu selection, disabled state, focus and status labels on rendered surfaces. Do not dim the entire document or selection to indicate inactivity.

## Exactly two columns

Two stable ordered containers share one document split value. Appearance never adds a third column or permits an indirect nested column layout. Preserve content and collection identity when stacking. Reading order is first container, then second, in both grid and stacked presentation.

The reference starts with a **20 em readable minimum per column** and a 24-unit gap. Given available document width `A`, body size `s`, gap `g` and stored split `r`, let `m = 20 × s` and `U = A − g`:

* If `U < 2m`, stack the containers and hide the divider; keep `r` unchanged.
* Otherwise render with `clamp(r, m/U, 1 − m/U)` so both columns remain readable. This presentation clamp does not write a new split or create Undo history.
* A deliberate resize command changes the stored split through the shared engine, with one author Undo group defined in ST-120. Provide a pointer handle with a generous hit region and a keyboard/assistive adjustable control with a label and value. Cancel restores the pre-gesture value.

The reference measures `m = 340` at size 17 and `m = 400` at size 20. With 48-unit desktop insets, it stacks at a 720 viewport; at 820 it shows columns for 17 but stacks for 20; at 960 both fit. Requested 30/50/70 splits clamp only the rendered widths. A doubled 34-unit reference body also stacks without rewriting the value. This models enlarged text, not a browser zoom or native Dynamic Type acceptance pass. Native implementations remeasure after system font/zoom changes rather than using a single device-width breakpoint. ST-121/ST-139 validate real host readability and navigation.

| Host | Translation / column presentation |
| --- | --- |
| macOS | System font families; pointer gutter and native context menu; readable document font distinct from app chrome; remeasure on window/text scale changes |
| iPhone / iPad | Scalable system text and native touch tools; iPhone commonly stacks; iPad stacks when available width or text scale requires it, regardless of device label |
| Android | System font families and scalable text; Compose/JNI renders shared structure; touch/menu/focus conventions and density-aware widths |
| visionOS | Native scalable text, spatial focus and target conventions; available window/text metrics decide stacking; no claim from desktop preview about spatial readability |
| watchOS / tvOS | Always stacked document order; native reading scale and focus. Retain richer blocks/metadata through the reduced reading/text/checklist/reorder surface; no full authoring controls added |
| React/WASM, later | CSS reference can guide rendering after native acceptance; current design preview neither integrates WASM nor accepts the browser lane |

## Rendered review and delivery boundary

The [evidence index](evidence/modern-editor-visual-2026-10-05/README.md) and [manifest](evidence/modern-editor-visual-2026-10-05/manifest.json) retain 48 original PNGs with source/fixture/capture-script SHA-256 hashes, browser versions, viewports, settings and measured layouts. All eight scenarios—long, blank, nested, media, table, contextual tools, columns and states—are captured in both light/dark at desktop/narrow widths. Six typography/width comparisons, serif/mono samples, large-text column captures and four WebKit samples supplement the Chromium matrix.

Automated checks find no document horizontal overflow, retain logical column order and split values, and verify readable non-stacked column minima in 24 threshold/split combinations. Token contrast passes; dark selection's muted-text pair was corrected during review. Render inspection confirms continuous text rhythm, readable dark contextual tools, scoped narrow table scrolling and a visible column divider. This completes ST-119's visual specification and rendered design evidence. It does not complete ST-121's interaction review, ST-139/ST-142 physical/accessibility checks or ST-143 native acceptance. ST-170 device access and ST-177 delivery capacity/dates remain open without blocking this design contract.

To reproduce, use the repository's installed Playwright browsers and run `node scripts/capture-modern-editor-visual.mjs` with a supported Node runtime. To explore the study, serve the repository root with a local static server and open `/docs/design/modern-editor-visual-preview.html`; its relative URLs read the token JSON and existing fixture.
