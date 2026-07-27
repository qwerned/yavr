// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "YAVR",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5")
    ],
    targets: [
        .target(
            name: "YAVRCore"
        ),
        .executableTarget(
            name: "yavr-cli",
            dependencies: [
                "YAVRCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .executableTarget(
            name: "YAVR",
            dependencies: [
                "YAVRCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            resources: [
                .copy("Resources/glossary.json")
            ]
        ),
        // Юнит-тесты как исполняемый таргет: на машинах с одними
        // Command Line Tools нет XCTest/swift-testing, поэтому swift run yavr-tests
        .executableTarget(
            name: "yavr-tests",
            dependencies: ["YAVRCore"]
        )
    ]
)
