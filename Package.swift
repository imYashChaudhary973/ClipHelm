// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipHelm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipHelmCore", targets: ["ClipHelmCore"]),
        .library(name: "ClipHelmSecurity", targets: ["ClipHelmSecurity"]),
        .library(name: "ClipHelmOpenRouter", targets: ["ClipHelmOpenRouter"]),
        .executable(name: "ClipHelmApp", targets: ["ClipHelmApp"]),
    ],
    targets: [
        .target(name: "ClipHelmCore"),
        .target(name: "ClipHelmSecurity"),
        .target(name: "ClipHelmOpenRouter", dependencies: ["ClipHelmSecurity"]),
        .executableTarget(name: "ClipHelmApp", dependencies: ["ClipHelmCore", "ClipHelmSecurity", "ClipHelmOpenRouter"]),
        .testTarget(name: "ClipHelmCoreTests", dependencies: ["ClipHelmCore"]),
        .testTarget(name: "ClipHelmSecurityTests", dependencies: ["ClipHelmSecurity"]),
        .testTarget(name: "ClipHelmOpenRouterTests", dependencies: ["ClipHelmOpenRouter", "ClipHelmSecurity"]),
        .testTarget(name: "ClipHelmAppTests", dependencies: ["ClipHelmApp", "ClipHelmCore"]),
    ]
)
