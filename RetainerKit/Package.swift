// swift-tools-version: 6.2
import PackageDescription

// All app code lives in this package so it can be built and tested with
// `swift build` / `swift test` as well as from the XcodeGen project.
let package = Package(
    name: "RetainerKit",
    platforms: [
        // The full feature set needs macOS 26 (SpeechAnalyzer, Foundation Models).
        // Those two are availability-gated so the app still launches on macOS 15
        // with Parakeet only. See README, "macOS version".
        .macOS(.v15)
    ],
    products: [
        .library(name: "RetainerKit", targets: ["RetainerKit"]),
        .executable(name: "RetainerMain", targets: ["RetainerMain"]),
    ],
    dependencies: [
        // Pinned exactly: FluidAudio's API moves quickly between minor versions.
        // `traits: []` builds ASR/VAD only (no TTS, diarization or the prebuilt
        // text-normalization binary), which is all this app uses.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: [])
    ],
    targets: [
        .target(
            name: "RetainerKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "RetainerMain",
            dependencies: ["RetainerKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RetainerKitTests",
            dependencies: ["RetainerKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
