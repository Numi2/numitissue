// swift-tools-version: 6.2
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .unsafeFlags(["-strict-concurrency=complete"]),
    .swiftLanguageMode(.v6)
]

let package = Package(
    name: "NumiTissue",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "NumiTissue", targets: ["NumiTissue"]),
        .library(name: "NumiTissueCore", targets: ["NumiTissueCore"]),
        .library(name: "NumiTissueModels", targets: ["NumiTissueModels"]),
        .library(name: "NumiTissueRuntime", targets: ["NumiTissueRuntime"]),
        .library(name: "NumiTissueIO", targets: ["NumiTissueIO"]),
        .library(name: "NumiTissueReference", targets: ["NumiTissueReference"]),
        .library(name: "NumiTissueMetal", targets: ["NumiTissueMetal"]),
        .library(name: "NumiTissueIntegration", targets: ["NumiTissueIntegration"]),
        .executable(name: "numitissue", targets: ["NumiTissueCLI"])
    ],
    targets: [
        .target(
            name: "NumiTissueCore",
            path: "Sources/NumiTissueCore",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "NumiTissueModels",
            dependencies: ["NumiTissueCore"],
            path: "Sources/NumiTissueModels",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "NumiTissueRuntime",
            dependencies: ["NumiTissueCore", "NumiTissueModels"],
            path: "Sources/NumiTissueRuntime",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "NumiTissueIO",
            dependencies: ["NumiTissueCore", "NumiTissueModels", "NumiTissueRuntime"],
            path: "Sources/NumiTissueIO",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "NumiTissueReference",
            dependencies: ["NumiTissueCore", "NumiTissueModels", "NumiTissueRuntime", "NumiTissueIO"],
            path: "Sources/NumiTissueReference",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "NumiTissueMetal",
            dependencies: ["NumiTissueCore", "NumiTissueModels", "NumiTissueRuntime", "NumiTissueIO"],
            path: "Sources/NumiTissueMetal",
            resources: [.process("Shaders")],
            swiftSettings: strictConcurrency + [.define("NUMITISSUE_METAL")],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate")
            ]
        ),
        .target(
            name: "NumiTissueIntegration",
            dependencies: ["NumiTissueCore", "NumiTissueModels", "NumiTissueRuntime", "NumiTissueIO"],
            path: "Sources/NumiTissueIntegration",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "NumiTissue",
            dependencies: [
                "NumiTissueCore",
                "NumiTissueModels",
                "NumiTissueRuntime",
                "NumiTissueIO",
                "NumiTissueReference",
                "NumiTissueMetal",
                "NumiTissueIntegration"
            ],
            path: "Sources/NumiTissue",
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "NumiTissueCLI",
            dependencies: ["NumiTissue"],
            path: "Sources/NumiTissueCLI",
            swiftSettings: strictConcurrency
        )
    ],
    swiftLanguageModes: [.v6]
)
