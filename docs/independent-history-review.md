# Independent retained author history review

The public JSON oracle in [`scripts/verify-retained-toggle-order.py`](../scripts/verify-retained-toggle-order.py) checks the retained author's history through a stopped and resumed editor incarnation. This supplements the Swift tests delivered in PR #37 and the legacy correction delivered in PR #43. It changes no engine behavior.

Start from paragraph `a`, insert `X`, and save after that edit. The original incarnation then undoes and redoes the edit. Restore the earlier snapshot as the same author and deliver the later Undo/Redo packets in both orders, including duplicates. The resumed document must contain `aX`, offer Undo rather than Redo, survive save/reopen with the same public state, and undo back to `a`. Run this for collaboration versions 1, 2 and 3. The expected result follows authored change identity rather than packet arrival order.

Run against an explicitly selected executable that implements the EditorBridgeCLI line-delimited JSON protocol:

```sh
python3 scripts/verify-retained-toggle-order.py /absolute/path/to/editor-bridge \
  --output /absolute/path/to/retained-toggle-report.json --expect-fixed
```

The executable must support all three versions to run the full oracle. A current legacy-only build is insufficient for its v3 cases. The script records the executable's SHA-256 and full requests/responses; `--expect-fixed` exits unsuccessfully if any case fails. The output destination must already have a parent directory. Keep generated transcripts outside tracked source.

The current oracle requires every bridge response, including reordered and duplicate packet delivery, to succeed and checks the complete resumed document against the literal `aX` paragraph. The historical script hash and execution receipts below retain their original qualification; they are not relabeled as execution of this stricter oracle.

## Recorded evidence and limits

[`independent-history-review.json`](independent-history-review.json) retains compact, source-qualified review receipts from 2026-10-01. Raw reports and binaries remain in the private orchestration evidence archive; this record does not package those binaries or replace fresh delivery checks.

- The pre-fix executable failed all three Redo-before-Undo cases while the forward order passed. The corrected portable executable passed all six cases, including duplicate delivery, save/reopen and final Undo. Both executable hashes are recorded.
- Native and actual Chromium, WebKit and Firefox fixture reports each contained 2,934 responses with identical report hashes. Six browser corpus/typed writing tests passed. This execution belongs to previous default `280545a8e211bc0235b929d27971deb2b3790108` plus candidate tree `907b586fc1efbb2203b031153f053b94856f958f`.
- The later source-only review compared candidate tree `31ba092bc898f0d5832379b5c7208e1aa32feeb4` with accepted default `f97db3023e2ce79cca534e6ac6e3b869eec37224`. All 11 accepted Apple files and the merged legacy correction were retained without unexpected default changes. The same 16-file v3 patch and 17 core/CLI/WASM compilation inputs were preserved. Six Apple inputs changed and two were added through PR #40. No execution on this later candidate is claimed.

Packaged JNI, a signed v3 candidate with fresh CI/review, and actual Apple, Android and browser IME/selection/focus/accessibility acceptance remain separate gates. ST-41 stays In Progress until its remaining text, marks and atomic-reference integration criterion is accepted through ST-102, ST-103 and ST-104. Core changes remain owned by ST-42.
