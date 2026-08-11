// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "MacSteam",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MacsTeam", targets: ["MacSteam"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MacsTeamNavigationCore",
            path: "Sources/MacsTeamNavigationCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "MacsTeamNavigationAudit",
            dependencies: ["MacsTeamNavigationCore"],
            path: "Sources/MacsTeamNavigationAudit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "MacSteam",
            dependencies: ["MacsTeamNavigationCore"],
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
            dependencies: ["MacSteam", "MacsTeamNavigationCore"],
            path: "Tests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
