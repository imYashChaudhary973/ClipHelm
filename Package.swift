// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipHelm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipHelmCore", targets: ["ClipHelmCore"]),
        .library(name: "ClipHelmSecurity", targets: ["ClipHelmSecurity"]),
        .library(name: "ClipHelmOpenRouter", targets: ["ClipHelmOpenRouter"]),
        .library(name: "ClipHelmMedia", targets: ["ClipHelmMedia"]),
        .library(name: "ClipHelmSources", targets: ["ClipHelmSources"]),
        .executable(name: "ClipHelmApp", targets: ["ClipHelmApp"]),
    ],
    targets: [
        .target(name: "ClipHelmCore"),
        .target(name: "ClipHelmSecurity"),
        .target(name: "ClipHelmOpenRouter", dependencies: ["ClipHelmSecurity"]),
        .target(name: "ClipHelmMedia", dependencies: ["ClipHelmCore"]),
        .target(name: "ClipHelmSources", dependencies: ["ClipHelmCore", "ClipHelmMedia"]),
        .executableTarget(name: "ClipHelmApp", dependencies: ["ClipHelmCore", "ClipHelmSecurity", "ClipHelmOpenRouter", "ClipHelmSources", "ClipHelmMedia"]),
        .testTarget(name: "ClipHelmCoreTests", dependencies: ["ClipHelmCore"]),
        .testTarget(name: "ClipHelmSecurityTests", dependencies: ["ClipHelmSecurity"]),
        .testTarget(name: "ClipHelmOpenRouterTests", dependencies: ["ClipHelmOpenRouter", "ClipHelmSecurity"]),
        .testTarget(name: "ClipHelmSourcesTests", dependencies: ["ClipHelmSources", "ClipHelmCore"], resources: [.process("Fixtures")]),
        .testTarget(name: "ClipHelmMediaTests", dependencies: ["ClipHelmMedia", "ClipHelmCore"], resources: [.process("Fixtures")]),
        .testTarget(name: "ClipHelmAppTests", dependencies: ["ClipHelmApp", "ClipHelmCore"]),
    ]
)
