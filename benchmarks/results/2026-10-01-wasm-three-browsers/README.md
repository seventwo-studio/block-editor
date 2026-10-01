# Repeated browser baseline at e787146

Chromium, WebKit and Firefox each complete all eight cases with one excluded warmup and three recorded repetitions: **72 complete browser samples**. [Independent verification](verification.txt) requires the full baseline profile, workload hash, exact archived source, complete call counts and matching preserved documents/history/receipts. Corresponding cases also match the separately preserved **24 native samples**, whose original report hash remains unchanged. Provenance records that canonical comparison; source stamps are not relabeled.

All browser measurements use clean checkout source `e787146c432e649e71a1a6423fe4a24c55e21f5c` and release WASM SHA-256 `d659fd2f1212d8242e3c18397f69a540cf76d23c63cd2e073eba15a669518457`. [Provenance](provenance.json) retains exact build command, source objects, compiler version/hash, SDK manifest/hash and report hashes; [the build log](wasm-build.log) records the pinned Swift 6.4 release build. The module is **61,435,676 raw bytes / 20,370,961 computed gzip level-9 bytes**. This is not deployed compression or installed application size. These are measurements of e787146, not later editor engine changes.

Browser runs were sequential on Apple M4 Max; each report records full host/OS/browser metadata. OS/browser caches and background load were uncontrolled. Timings include UTF-8, JSON and WASM copies through `SwiftEditorRuntime.call`, excluding network, rendering and input-to-frame latency. Three repetitions do not establish a confidence interval or accepted numerical budget.

## Edit-call p95

Entries list repetitions 0/1/2 in milliseconds.

| Case | Chromium 153.0.8010.12 | WebKit 26.6 | Firefox 155.0 |
| --- | ---: | ---: | ---: |
| ordinary-v1 | 1.00/1.00/1.00 | 1.00/1.00/1.00 | 2.00/2.00/2.00 |
| ordinary-v2 | 4.50/4.60/4.50 | 5.00/4.00/5.00 | 6.00/6.00/6.00 |
| history-v1-128 | 1.10/1.10/1.10 | 1.00/1.00/1.00 | 2.00/2.00/3.00 |
| history-v1-512 | 1.80/1.80/1.80 | 2.00/2.00/2.00 | 3.00/3.00/3.00 |
| history-v1-2048 | 5.00/5.00/5.00 | 5.00/5.00/5.00 | 6.00/7.00/6.00 |
| history-v2-128 | 6.10/6.20/6.20 | 6.00/6.00/6.00 | 8.00/9.00/8.00 |
| history-v2-512 | 12.70/12.70/12.70 | 12.00/12.00/12.00 | 16.00/17.00/16.00 |
| history-v2-2048 | 41.00/41.40/41.50 | 38.00/38.00/38.00 | 52.00/52.00/50.00 |

For 2,048 v2 edits per author, the two rejoin calls total **1173.40/1160.00/1136.50 ms** in Chromium, **1001.00/992.00/1014.00 ms** in WebKit and **1546.00/1469.00/1454.00 ms** in Firefox. Each largest case retains 4,098 changes and receipts. No compaction, peak-memory bound or unbounded-history scalability is established.

## Observed initialization

These are one observed initialization sequence per browser, after fetching local module bytes, rather than repeated cold application launches.

| Browser | Compile ms | Compiled-module instantiate ms | First empty session ms |
| --- | ---: | ---: | ---: |
| chromium 153.0.8010.12 | 21.50 | 8.80 | 7.90 |
| webkit 26.6 | 40.00 | 10.00 | 8.00 |
| firefox 155.0 | 88.00 | 6.00 | 0.00 |

## Firefox launch recovery

Original launch and a TMPDIR-only retry failed before testing. Mozilla's [directory-provider source](https://searchfox.org/firefox-main/source/toolkit/xre/nsXREDirProvider.cpp) supports separate process-level application-data roots. The successful run scopes `TMPDIR=/tmp`, `MOZ_APP_DATA` and `MOZ_LOCAL_APP_DATA` to the child process, with application-data directories created in an owned temporary namespace. [Launch provenance](launch-provenance.json) records the paths and successful cleanup, independently checked after the run. The installed Firefox binary, branding, browser revision and user profiles remain unchanged; no download, signing change, Full Disk Access grant or system-setting change was made.

The [earlier TMPDIR-only failure](firefox-tmpdir-only-failed.log) and [successful full-run log](firefox-playwright.log) are retained. [The upstream Playwright issue](https://github.com/microsoft/playwright/issues/42768) describes matching macOS 27 app-data lookup failures; that is supporting context, not proof that this host produced a particular TCC denial.

## Reproduce and remaining acceptance

```sh
bun scripts/compare-performance-reports.mjs \
  benchmarks/results/2026-10-01-wasm-three-browsers \
  wasm-chromium,wasm-webkit,wasm-firefox baseline \
  --source=e787146c432e649e71a1a6423fe4a24c55e21f5c
```

A safe per-process Firefox runner creates owned temporary `app` and `local` directories, passes `MOZ_APP_DATA`/`MOZ_LOCAL_APP_DATA` only to its Playwright child, and removes only that created namespace afterward. No Chromium/WebKit rerun was needed: their original fresh-artifact reports were copied byte-for-byte and their hashes remain recorded. Earlier two-browser and reused-artifact archives remain unchanged.

The 16 ms edit p95 / 1 second two-call rejoin / 10 MB gzip values remain **unagreed discussion targets**. Repeated JNI/device baselines, actual system input/rendering/accessibility, resource thresholds, numerical agreement and any resulting improvements remain open. Files are local uncommitted evidence, not merged dataset delivery or private-package acceptance.

[Chromium report](performance-wasm-chromium.json) · [WebKit report](performance-wasm-webkit.json) · [Firefox report](performance-wasm-firefox.json) · [Methods](../../../docs/editor-performance.md)
