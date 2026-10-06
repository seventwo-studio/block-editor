// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ModernInteractionPrototype",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "ModernInteractionPrototype", targets: ["ModernInteractionPrototype"])],
    dependencies: [.package(name: "BlockEditor", path: "../..")],
    targets: [.executableTarget(name: "ModernInteractionPrototype", dependencies: [
        .product(name: "BlockEditorCore", package: "BlockEditor")
    ], path: "App")]
)
