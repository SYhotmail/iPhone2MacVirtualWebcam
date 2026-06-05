// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Transport",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "Transport",
            targets: ["Transport"]
        ),
    ],
    targets: [
        .target(
            name: "Transport"
        ),
        .testTarget(
            name: "TransportTests",
            dependencies: ["Transport"]
        ),
    ]
)
