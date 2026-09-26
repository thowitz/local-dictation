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
        // Input method bundle executable (scripts/build-input-method.sh wraps it).
        .executable(name: "LocalDictationInputMethod", targets: ["LocalDictationInputMethod"]),
        // Live input-method harness for real apps (development only).
        .executable(name: "LocalDictationIMEHarness", targets: ["LocalDictationIMEHarness"]),
    ],
    dependencies: [
        // Parakeet TDT CoreML ASR (optional at runtime; selected via config `provider`).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4"),
    ],
    targets: [
        // Testable library of app sources. `@main` lives in LocalDictationApp so
        // Swift Testing can load this module without colliding with the package
        // tests runner entry point.
        .target(
            name: "LocalDictation",
            dependencies: [
                "LocalDictationIME",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/LocalDictation"
        ),
        // Shared app <-> input method protocol and the marked-text composer.
        .target(
            name: "LocalDictationIME",
            path: "Sources/LocalDictationIME"
        ),
        .executableTarget(
            name: "LocalDictationInputMethod",
            dependencies: ["LocalDictationIME"],
            path: "Sources/LocalDictationInputMethod",
            linkerSettings: [.linkedFramework("InputMethodKit")]
        ),
        .executableTarget(
            name: "LocalDictationIMEHarness",
            dependencies: ["LocalDictation", "LocalDictationIME"],
            path: "Sources/LocalDictationIMEHarness"
        ),
        .executableTarget(
            name: "LocalDictationApp",
            dependencies: ["LocalDictation"],
            path: "Sources/LocalDictationMain"
        ),
        .testTarget(
            name: "LocalDictationTests",
            dependencies: ["LocalDictation", "LocalDictationIME"],
            path: "Tests/LocalDictationTests"
        ),
    ]
)
