// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipHelm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipHelmCore", targets: ["ClipHelmCore"]),
        .executable(name: "ClipHelmApp", targets: ["ClipHelmApp"]),
    ],
    targets: [
        .target(name: "ClipHelmCore"),
        .executableTarget(name: "ClipHelmApp", dependencies: ["ClipHelmCore"]),
        .testTarget(name: "ClipHelmCoreTests", dependencies: ["ClipHelmCore"]),
        .testTarget(name: "ClipHelmAppTests", dependencies: ["ClipHelmApp", "ClipHelmCore"]),
    ]
)
