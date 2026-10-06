# ST-119 rendered visual reference

These are original automated captures of the [visual study](../../design/modern-editor-visual-preview.html), implementing the [visual contract](../../modern-editor-visual-contract.md). They demonstrate the proposed document appearance, not the production shared editor or native runtime acceptance. The study reads the existing Apple demo mixed fixture directly; supplemental prose, illustration/file and wide-table examples are design samples.

The [manifest](manifest.json) records source hashes, browser versions, viewport/settings, every image hash, contrast ratios, measured line lengths, overflow and column checks. Reproduce with `node scripts/capture-modern-editor-visual.mjs` using the installed Playwright browsers. No QuickTime, user desktop recording or physical device is required.

| Coverage | Captures |
| --- | --- |
| Long, blank, nested, media, table, contextual, columns and states × light/dark × 1440/390 | 32 Chromium PNGs |
| 680/720/760 reading width × 16/17 body text | 6 Chromium PNGs |
| Serif/monospace, dark narrow | 2 Chromium PNGs |
| Large-text columns, light/dark at 1440/720 | 4 Chromium PNGs |
| Dark long desktop, dark contextual narrow, light table narrow, dark columns desktop | 4 WebKit PNGs |

Representative renders reviewed directly:

* [Long light desktop](chromium-long-light-1440.png), [long dark desktop](webkit-long-dark-1440.png) and [blank dark narrow](chromium-blank-dark-390.png).
* [Nested light narrow](chromium-nested-light-390.png), [media dark narrow](chromium-media-dark-390.png) and [wide table light narrow](chromium-table-light-390.png).
* [Contextual dark narrow](chromium-contextual-dark-390.png), [states dark desktop](chromium-states-dark-1440.png) and [columns dark desktop](chromium-columns-dark-1440.png).
* [Large-text columns stacked](chromium-columns-dark-720-large-text-stack.png) and [serif dark narrow](chromium-long-dark-390-serif.png).

The reference has no document horizontal overflow in the captured cases. Twenty-four additional size/viewport/split combinations preserve the requested split and reading order, with minimum widths respected whenever columns fit. Semantic text/fill pairs and authored focus/control-border pairs pass their computed contrast thresholds. Enlarging the reference body to 34 also stacks; actual browser zoom, native text scaling, input, focus restoration and assistive technology remain later acceptance work.
