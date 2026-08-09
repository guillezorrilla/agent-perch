// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VibeNotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VibeNotch", targets: ["VibeNotch"])
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "VibeNotch",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VibeNotchTests",
            dependencies: ["VibeNotch"]
        )
    ]
)
