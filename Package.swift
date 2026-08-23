// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentPerch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentPerch", targets: ["AgentPerch"])
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "AgentPerch",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentPerchTests",
            dependencies: ["AgentPerch"]
        )
    ]
)
