// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        // Preserve `.build/.../LocalDictation` binary path used by the Makefile.
        .executable(name: "LocalDictation", targets: ["LocalDictationApp"]),
    ],
    targets: [
        // Testable library of app sources. `@main` lives in LocalDictationApp so
        // Swift Testing can load this module without colliding with the package
        // tests runner entry point.
        .target(
            name: "LocalDictation",
            path: "Sources/LocalDictation"
        ),
        .executableTarget(
            name: "LocalDictationApp",
            dependencies: ["LocalDictation"],
            path: "Sources/LocalDictationMain"
        ),
        .testTarget(
            name: "LocalDictationTests",
            dependencies: ["LocalDictation"],
            path: "Tests/LocalDictationTests"
        ),
    ]
)
