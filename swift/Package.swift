// swift-tools-version: 6.0
import PackageDescription

// macOS keeps the menubar product; Linux drops it. SPM lets us
// conditionalize the targets/products arrays at manifest-eval time
// using a top-level #if. Without this gate, ``swift build`` on Linux
// fails immediately because the menubar target imports AppKit which
// has no Linux equivalent.
//
// The daemon (``rmsync``) and the codec library (``RMScene``) build
// on both platforms; everything Linux-specific lives behind
// ``#if os(Linux)`` inside the ``rmsync`` target's source files.

#if os(macOS)
let menubarProducts: [Product] = [
    .executable(name: "rmsync-menubar", targets: ["rmsync-menubar"]),
]
let menubarTargets: [Target] = [
    .executableTarget(
        name: "rmsync-menubar",
        path: "Sources/rmsync-menubar"
    ),
]
#else
let menubarProducts: [Product] = []
let menubarTargets: [Target] = []
#endif

let package = Package(
    name: "rmsync-suite",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "rmsync", targets: ["rmsync"]),
        .library(name: "RMScene", targets: ["RMScene"]),
    ] + menubarProducts,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", from: "0.2.2"),
        // swift-crypto is the Linux-side fallback for CryptoKit. The
        // ``rmsync`` target's ``PathUtilities.sha256Hex`` uses
        // ``CryptoKit.SHA256`` on macOS and ``Crypto.SHA256`` on
        // Linux (same API surface). We declare the dependency
        // unconditionally because SPM manifest-time ``#if os(...)``
        // is awkward to combine with Linux-only target deps; macOS
        // builds pull the framework but never import ``Crypto`` (the
        // ``canImport(CryptoKit)`` branch wins first), so the cost
        // is negligible. Pinned to 3.x — same major as the latest
        // upstream release at the time of writing.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // Swift port of Rick Lupton's Python ``rmscene``
        // (https://github.com/ricklupton/rmscene, MIT). Lives in-tree
        // rather than as a git-submodule dep so builds are hermetic
        // and the licensing story (a derivative work of an MIT-licensed
        // project) is entirely visible in this repo — see
        // ``Sources/RMScene/LICENSE`` for the dual-attribution text.
        // Tests moved to ``Tests/RMSceneTests``.
        //
        // ``exclude`` tells SPM the LICENSE file is intentional metadata,
        // not a source or resource to bundle. Without this, ``swift
        // build`` emits a "unhandled file" warning every compile.
        .target(
            name: "RMScene",
            exclude: ["LICENSE"]
        ),
        .executableTarget(
            name: "rmsync",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
                // ``Crypto`` is only ``import``ed on Linux (see
                // PathUtilities.swift's ``canImport(CryptoKit)`` /
                // ``#else import Crypto`` block); macOS uses the
                // built-in CryptoKit. Listing it as a dep here is
                // required for the import to resolve on Linux.
                .product(name: "Crypto", package: "swift-crypto"),
                "RMScene",
            ],
            path: "Sources/rmsync",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
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
    ] + menubarTargets,
    swiftLanguageModes: [.v6]
)
