# Reused-artifact Chromium screening

This completed Chromium run contains 24 samples at clean harness source e787146. It used an existing historical WASM artifact with SHA-256 `9d84110e2f8b3a08ff7429cfb6114da2d7dd64a4902ed28ec9565aa08821c715`. The artifact matched earlier release reports from a dirty harness-development checkout, whose complete original build tree was not archived. Tracked production sources were unchanged, but that did not establish fresh exact-source compilation provenance.

A rebuild from clean e787146 produced a different hash. Therefore this run was retained as qualified screening and excluded from the [fresh browser baseline](../2026-10-01-wasm-repeated/README.md). No source or artifact metadata was relabeled. The raw report and provenance remain available for inspection; they do not establish numerical acceptance or performance of later engine revisions.
