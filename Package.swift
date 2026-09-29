// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "BlockEditor",
    platforms: [.macOS(.v26), .iOS(.v26), .tvOS(.v26), .watchOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "BlockEditorCore", targets: ["BlockEditorCore"]),
        .library(name: "BlockEditorApple", targets: ["BlockEditorApple"]),
        .library(name: "BlockEditorBridge", type: .dynamic, targets: ["BlockEditorABI"]),
        .executable(name: "block-editor-wasm", targets: ["BlockEditorWasm"]),
        .executable(name: "local-editor", targets: ["LocalEditor"]),
        .executable(name: "collaborative-editor", targets: ["CollaborativeEditor"]),
    ],
    targets: [
        .target(name: "BlockEditorCore"),
        .target(name: "BlockEditorApple", dependencies: ["BlockEditorCore"]),
        .target(name: "BlockEditorABI", dependencies: ["BlockEditorCore"]),
        .executableTarget(name: "BlockEditorWasm", dependencies: ["BlockEditorABI"]),
        .executableTarget(name: "LocalEditor", dependencies: ["BlockEditorCore"], path: "Examples/LocalEditor"),
        .executableTarget(name: "CollaborativeEditor", dependencies: ["BlockEditorCore"], path: "Examples/CollaborativeEditor"),
        .testTarget(name: "BlockEditorCoreTests", dependencies: ["BlockEditorCore"], path: "tests/BlockEditorCoreTests", resources: [.copy("Fixtures")]),
    ]
)
