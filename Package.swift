// swift-tools-version: 6.2
import PackageDescription

// Foundation-only transport contracts can run on macOS without a simulator or
// signing. The Xcode app build separately compiles the AVFoundation integration.
let package = Package(
    name: "NativeAudioTransport",
    platforms: [.macOS(.v13)],
    products: [.library(name: "NativeAudioTransport", targets: ["NativeAudioTransport"])],
    targets: [
        .target(
            name: "NativeAudioTransport",
            path: "Services",
            sources: [
                "Player/HTTPAudioRangeClient.swift",
                "Player/MixtapeHTTPAudioTransfer.swift",
                "API/Models/PlayerResponse.swift",
            ]
        ),
        .testTarget(
            name: "NativeAudioTransportTests",
            dependencies: ["NativeAudioTransport"],
            path: "Tests/NativeAudioTransportTests",
            exclude: ["Fixtures"]
        ),
    ]
)
