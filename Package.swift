// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MeetingHUD",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMinor(from: "0.30.6")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "2.30.0"),
        .package(url: "https://github.com/soniqo/speech-swift.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingHUD",
            dependencies: [
                "WhisperKit",
                .product(name: "SpeakerKit", package: "WhisperKit"),
                "KeyboardShortcuts",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "SpeechVAD", package: "speech-swift"),
            ],
            path: "Sources/MeetingHUD",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
