// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "apfelclaw-server",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "ApfelClawCore", targets: ["ApfelClawCore"]),
        .library(name: "ApfelClawServerRuntime", targets: ["ApfelClawServerRuntime"]),
        .executable(name: "apfelclaw-backend", targets: ["apfelclaw-backend"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
    ],
    targets: [
        .target(
            name: "ApfelClawCore",
            dependencies: [],
            path: "Sources/ApfelClawCore",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("EventKit"),
                .linkedFramework("IOKit"),
            ]
        ),
        .target(
            name: "ApfelClawServerRuntime",
            dependencies: [
                "ApfelClawCore",
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Sources/ApfelClawServerRuntime"
        ),
        .executableTarget(
            name: "apfelclaw-backend",
            dependencies: [
                "ApfelClawServerRuntime",
            ],
            path: "Sources/apfelclaw-backend"
        ),
        .testTarget(
            name: "AgentTests",
            dependencies: ["ApfelClawCore"],
            path: "Tests/AgentTests"
        ),
        .testTarget(
            name: "ApfelTests",
            dependencies: ["ApfelClawCore"],
            path: "Tests/ApfelTests"
        ),
        .testTarget(
            name: "MemoryTests",
            dependencies: ["ApfelClawCore"],
            path: "Tests/MemoryTests"
        ),
        .testTarget(
            name: "ToolTests",
            dependencies: ["ApfelClawCore"],
            path: "Tests/ToolTests"
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["ApfelClawCore", "ApfelClawServerRuntime"],
            path: "Tests/IntegrationTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
