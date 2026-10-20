// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LanShare",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LanShare", targets: ["LanShareApp"])],
    targets: [
        .executableTarget(name: "LanShareApp", path: "Sources/LanShareApp")
    ]
)
