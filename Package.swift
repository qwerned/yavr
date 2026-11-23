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
        // transcribe.cpp (Whisper GGUF + Silero VAD, Metal) — тот же движок
        // и та же сборка модели, что у Орки. Нативная часть — динамический
        // CTranscribe.framework, make-app.sh кладёт его в Contents/Frameworks.
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.4.1/TranscribeCpp.xcframework.zip",
            checksum: "fb5646e564036a6c49659e3efcf72eb567af20da31b8569045c9a08181d35126"
        ),
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            exclude: ["LICENSE", "README.md"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
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
                "TranscribeCpp",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            resources: [
                .copy("Resources/glossary.json")
            ],
            linkerSettings: [
                // CTranscribe.framework лежит в YAVR.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
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
