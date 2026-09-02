// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NumiTissue",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "NumiTissue", targets: ["NumiTissue"]),
        .library(name: "NumiTissueCore", targets: ["NumiTissueCore"]),
        .library(name: "NumiTissueModels", targets: ["NumiTissueModels"]),
        .library(name: "NumiTissueMetal", targets: ["NumiTissueMetal"]),
        .library(name: "NumiTissueReference", targets: ["NumiTissueReference"]),
        .executable(name: "numitissue", targets: ["NumiTissueCLI"])
    ],
    targets: [
        .target(
            name: "NumiTissueCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NumiTissueModels",
            dependencies: ["NumiTissueCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NumiTissueReference",
            dependencies: ["NumiTissueCore", "NumiTissueModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NumiTissueMetal",
            dependencies: ["NumiTissueCore", "NumiTissueModels"],
            resources: [.copy("Shaders")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NumiTissueIO",
            dependencies: ["NumiTissueCore", "NumiTissueModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NumiTissueWetware",
            dependencies: ["NumiTissueCore", "NumiTissueModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NumiTissueIntegration",
            dependencies: ["NumiTissueCore", "NumiTissueModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NumiTissue",
            dependencies: [
                "NumiTissueCore",
                "NumiTissueModels",
                "NumiTissueReference",
                "NumiTissueMetal",
                "NumiTissueIO",
                "NumiTissueWetware",
                "NumiTissueIntegration"
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "NumiTissueCLI",
            dependencies: ["NumiTissue"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NumiTissueCoreTests",
            dependencies: ["NumiTissueCore", "NumiTissueModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ],
    swiftLanguageModes: [.v6]
)
