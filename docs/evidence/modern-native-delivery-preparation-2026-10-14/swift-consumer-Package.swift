// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "NativeConsumerSmoke", platforms: [.macOS(.v26)], dependencies: [.package(url: "file:///private/tmp/modern-swift-preparation-smoke-fe5a515/block-editor-internal-packages", exact: "0.2.1")], targets: [.executableTarget(name: "Smoke", dependencies: [.product(name: "BlockEditorCore", package: "block-editor-internal-packages")])])
