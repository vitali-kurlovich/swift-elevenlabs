// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FluidSpeech",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FluidSpeech",
            path: "Sources/FluidSpeech"
        ),
    ]
)
