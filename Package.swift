// swift-tools-version:5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GSPlayer",
    platforms: [.iOS(.v16),
                .macOS(.v11)],
    products: [
        .library(
            name: "GSPlayer",
            targets: ["GSPlayer"]
        ),
    ],
    targets: [
        .target(
            name: "GSPlayer",
            path: "GSPlayer/Classes"
        ),
    ]
)
