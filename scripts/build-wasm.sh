#!/bin/sh
set -eu
# Use the matching open-source Swift 6.4 toolchain, not Xcode's compiler.
SWIFT_BIN=${SWIFT_BIN:-swift}
"$SWIFT_BIN" build --swift-sdk swift-6.4.0-RELEASE_wasm \
  --scratch-path .build/wasm --product block-editor-wasm -c release \
  -Xlinker --export=block_editor_alloc -Xlinker --export=block_editor_free \
  -Xlinker --export=block_editor_call -Xlinker --strip-debug "$@"
WASM_BIN_DIR=$("$SWIFT_BIN" build --swift-sdk swift-6.4.0-RELEASE_wasm --scratch-path .build/wasm -c release --show-bin-path "$@")
mkdir -p dist
cp "$WASM_BIN_DIR/block-editor-wasm.wasm" dist/block-editor.wasm
mkdir -p demo/public
cp dist/block-editor.wasm demo/public/block-editor.wasm

SWIFT_BIN="$SWIFT_BIN" node scripts/record-modern-build.mjs wasm
