// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipHelm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipHelmCore", targets: ["ClipHelmCore"]),
    ],
    targets: [
        .target(name: "ClipHelmCore"),
        .testTarget(name: "ClipHelmCoreTests", dependencies: ["ClipHelmCore"]),
    ]
)
