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
    dependencies: [
        // Parakeet TDT CoreML ASR (optional at runtime; selected via config `provider`).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        // Testable library of app sources. `@main` lives in LocalDictationApp so
        // Swift Testing can load this module without colliding with the package
        // tests runner entry point.
        .target(
            name: "LocalDictation",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
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
