// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ElevenLabsClient",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ElevenLabs", targets: ["ElevenLabs"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "ElevenLabs",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        .executableTarget(
            name: "elevenlabs-demo",
            dependencies: ["ElevenLabs"]
        ),
    ]
)
