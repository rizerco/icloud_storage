// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "icloud_storage",
    platforms: [
        .iOS("12.0"),
        .macOS("10.14"),
    ],
    products: [
        .library(name: "icloud-storage", targets: ["icloud_storage"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "icloud_storage",
            dependencies: [],
            resources: []
        ),
    ]
)
