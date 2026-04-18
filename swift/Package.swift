// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "rmsync-suite",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "rmsync", targets: ["rmsync"]),
        .executable(name: "rmsync-menubar", targets: ["rmsync-menubar"]),
        .library(name: "RMScene", targets: ["RMScene"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", from: "0.2.2"),
    ],
    targets: [
        // Vendored in-tree from github.com/madhav/rmscene-swift. Keeping
        // the package local (no external git dep) so builds are hermetic
        // and a git submodule dance is avoided. The sources are copied
        // verbatim; their tests moved to ``Tests/RMSceneTests``.
        .target(
            name: "RMScene"
        ),
        .executableTarget(
            name: "rmsync",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
                "RMScene",
            ],
            path: "Sources/rmsync",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "rmsync-menubar",
            path: "Sources/rmsync-menubar"
        ),
        .testTarget(
            name: "rmsyncTests",
            dependencies: ["rmsync"],
            path: "Tests/rmsyncTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "RMSceneTests",
            dependencies: ["RMScene"],
            path: "Tests/RMSceneTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
