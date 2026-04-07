// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "apfelclaw-server",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "ApfelClawCore", targets: ["ApfelClawCore"]),
        .executable(name: "apfelclaw-server", targets: ["apfelclaw-server"]),
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
            ]
        ),
        .executableTarget(
            name: "apfelclaw-server",
            dependencies: [
                "ApfelClawCore",
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Sources/apfelclaw-server"
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
            dependencies: ["ApfelClawCore"],
            path: "Tests/IntegrationTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
