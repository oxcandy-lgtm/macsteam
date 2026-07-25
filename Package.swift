// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "MacSteam",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MacSteam", targets: ["MacSteam"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MacSteam",
            dependencies: [],
            path: "Sources/MacSteam",
            resources: [
                .copy("Resources/Recipes")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MacSteamTests",
            dependencies: ["MacSteam"],
            path: "Tests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
