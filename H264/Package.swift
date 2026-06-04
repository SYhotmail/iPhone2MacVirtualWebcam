// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "H264",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "H264",
            targets: ["H264"]
        ),
    ],
    targets: [
        .target(
            name: "H264"
        ),
        .testTarget(
            name: "H264Tests",
            dependencies: ["H264"]
        ),
    ]
)
