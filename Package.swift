// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "BlockEditor",
    platforms: [.macOS(.v26), .iOS(.v26), .tvOS(.v26), .watchOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "BlockEditorCore", targets: ["BlockEditorCore"]),
        .library(name: "BlockEditorApple", targets: ["BlockEditorApple"]),
        .library(name: "BlockEditorLocalDemo", targets: ["BlockEditorLocalDemo"]),
        .library(name: "BlockEditorDemoApple", targets: ["BlockEditorDemoApple"]),
        .library(name: "BlockEditorBridge", type: .dynamic, targets: ["BlockEditorABI"]),
        .executable(name: "block-editor-wasm", targets: ["BlockEditorWasm"]),
        .executable(name: "local-editor", targets: ["LocalEditor"]),
        .executable(name: "collaborative-editor", targets: ["CollaborativeEditor"]),
        .executable(name: "editor-bridge", targets: ["EditorBridgeCLI"]),
        .executable(name: "relay-client", targets: ["RelayClient"]),
        .executable(name: "local-editor-app", targets: ["LocalEditorApp"]),
    ],
    targets: [
        .target(name: "BlockEditorCore"),
        .target(name: "BlockEditorApple", dependencies: ["BlockEditorCore"]),
        .target(name: "BlockEditorLocalDemo", dependencies: ["BlockEditorCore"]),
        .target(name: "BlockEditorDemoApple", dependencies: ["BlockEditorApple", "BlockEditorLocalDemo"]),
        .target(name: "BlockEditorABI", dependencies: ["BlockEditorCore"]),
        .executableTarget(name: "BlockEditorWasm", dependencies: ["BlockEditorABI"]),
        .executableTarget(name: "LocalEditor", dependencies: ["BlockEditorCore"], path: "Examples/LocalEditor"),
        .executableTarget(name: "CollaborativeEditor", dependencies: ["BlockEditorCore"], path: "Examples/CollaborativeEditor"),
        .executableTarget(name: "EditorBridgeCLI", dependencies: ["BlockEditorCore"], path: "Examples/EditorBridgeCLI"),
        .executableTarget(name: "RelayClient", dependencies: ["BlockEditorLocalDemo"], path: "Examples/RelayClient"),
        .executableTarget(name: "LocalEditorApp", dependencies: ["BlockEditorDemoApple"], path: "Examples/LocalEditorApp"),
        .testTarget(name: "BlockEditorCoreTests", dependencies: ["BlockEditorCore"], path: "tests/BlockEditorCoreTests", resources: [.copy("Fixtures")]),
    ]
)
