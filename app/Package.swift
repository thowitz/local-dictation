// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [
        .macOS(.v15),
    ],
    targets: [
        .executableTarget(
            name: "LocalDictation",
            path: "Sources/LocalDictation"
        ),
    ]
)
