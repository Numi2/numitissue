// swift-tools-version: 6.0
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .unsafeFlags(["-strict-concurrency=complete"])
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
        .library(name: "NumiTissueData", targets: ["NumiTissueData"]),
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
            dependencies: ["NumiTissueCore", "NumiTissueRuntime"],
            path: "Sources/NumiTissueIO",
            exclude: [
                "NeuroML.swift",
                "SBML.swift",
                "NMODLImporter.swift"
            ],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "NumiTissueData",
            dependencies: ["NumiTissueCore", "NumiTissueModels", "NumiTissueIO"],
            path: "Sources/NumiTissueData",
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
                "NumiTissueData",
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
        ),
        .testTarget(
            name: "NumiTissueValidationTests",
            dependencies: [
                "NumiTissue",
                "NumiTissueCore",
                "NumiTissueModels",
                "NumiTissueRuntime",
                "NumiTissueIO",
                "NumiTissueReference",
                "NumiTissueIntegration"
            ],
            path: "ValidationCases",
            exclude: ["README.md"],
            resources: [.copy("Cases")],
            swiftSettings: strictConcurrency
        )
    ],
    swiftLanguageModes: [.v6]
)
