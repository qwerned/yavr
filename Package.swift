// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Vox",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5")
    ],
    targets: [
        .target(
            name: "VoxCore"
        ),
        .executableTarget(
            name: "vox-cli",
            dependencies: [
                "VoxCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .executableTarget(
            name: "Vox",
            dependencies: [
                "VoxCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            resources: [
                .copy("Resources/glossary.json")
            ]
        ),
        // Юнит-тесты как исполняемый таргет: на машинах с одними
        // Command Line Tools нет XCTest/swift-testing, поэтому swift run vox-tests
        .executableTarget(
            name: "vox-tests",
            dependencies: ["VoxCore"]
        )
    ]
)
