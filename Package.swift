// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "AimatePet",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "AimateCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AimatePet",
            dependencies: ["AimateCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "pet-cli",
            dependencies: ["AimateCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AimateCoreTests",
            dependencies: ["AimateCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
