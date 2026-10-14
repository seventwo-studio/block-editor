# Private installed-runtime acceptance

ST-106 requires clean published Swift, Kotlin/AAR and JavaScript/WASM consumers.
A local checkout, packed proposal or build cache does not establish that result.
The private 0.2.0 npm release remains immutable; finishing changes need a new
reviewed, versioned delivery with the original approval and Verified-source gates.

## Registry-installed JavaScript/WASM

Copy `scripts/verify-modern-installed-package.mjs` into a separate consumer whose
manifest pins `@seventwo-studio/block-editor-internal` to `0.2.0`. Resolve it from
the private registry with scripts disabled and fresh package-manager cache/store.
Use an already approved read identity; isolate temporary registry configuration
outside every checkout and remove it afterward. Never save tokens or signed URLs.

Run the copied verifier with the consumer directory and an output receipt path.
It checks installed source/artifact provenance, incompatible ABI rejection and
actual WASM editing of an independently specified two-column document. Unicode
title/appearance, opaque data, atomic references, split/order, stable origins and
author Undo/Redo must survive save/reopen. This API smoke does not accept browser
interaction, native installation, performance or assistive campaigns.

The approved registry integrity remains
`sha512-A+nezh1ZE/jyArE3cPXk5n6ywtfN4KZOhSsIorgNRBzuZC5BfNzCVZkUy9+i77z/X65sKtc2zGjCz0XRnK/RIw==`.
Its delivered source is `1bb9a89c3f73c043588f8acabcde62c4e1b16be3`; later fixes in
the finishing PR are not contained in that existing release.

## Native delivery gap and proposed completion path

The current private handoff defines npm installation. Its installed inventory
contains neither Swift sources nor an AAR; source tags/releases did not identify
a versioned native path at this review. ST-106 therefore remains incomplete.
Source compilation and CI artifacts must not be substituted for published
private native installation.

Prepare the following after the finishing source is reviewed and delivered:

1. Select a new unused common version and pin the exact GitHub Verified source
   and tree. Never overwrite private 0.2.0 or mix source revisions across runtimes.
2. Stage the complete Swift package in the existing private publisher, with a
   versioned Git reference and source receipt. Preserve its package paths,
   platform products and required resources. A clean scratch dependency resolves
   that private Git URL/reference rather than a local path or archive.
3. Stage a Maven POM and Kotlin/Compose AAR built from the same source, containing
   matching arm64-v8a and x86_64 JNI binaries, dependency declarations and
   source/runtime/version hashes. A clean Gradle consumer resolves the exact
   private Maven coordinate and exercises the installed JNI API.
4. Stage matching JavaScript/WASM publication and all three clean consumers.
   Compare the same independent title/appearance/two-column edit/reopen outcomes;
   reject incompatible pairs explicitly and retain original failures.
5. Request concrete approval for the exact private source/workflow deployment,
   publication and necessary native consumer read path. Existing npm Actions
   Read does not establish private Git or Maven access. Prefer scoped job tokens
   where the approved repository boundaries allow them; do not expand credentials
   or grants to bypass this missing access contract.
6. After approval and actual publication, run fresh-cache consumers against the
   registry/Git paths, verify anonymous denial where applicable, record their
   receipts and only then consider ST-106 complete.

GitHub documents npm and Maven/Gradle registries, but lists no Swift registry;
the proposed Swift route is a private versioned Git package, not a fictional
GitHub Packages Swift endpoint. Package permissions vary by registry. See
[GitHub's supported clients and authentication](https://docs.github.com/en/packages/learn-github-packages/introduction-to-github-packages).

This is a preparation plan, not a deployed native release or an approved new
consumer grant. Keep the $0 Packages cap, Stop usage, existing credential
boundaries and concurrent Foliostrate work intact. Physical/final acceptance
remains separately deferred in the finishing project.
