// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TwitterTextEditor",
    platforms: [
        .iOS(.v16),
        .macCatalyst(.v16)
    ],
    products: [
        .library(
            name: "TwitterTextEditor-Auto",
            targets: [
                "TwitterTextEditor"
            ]
        ),
        .library(
            name: "TwitterTextEditor",
            type: .dynamic,
            targets: [
                "TwitterTextEditor"
            ]
        )
    ],
    targets: [
        .target(
            name: "TwitterTextEditor",
            dependencies: []
        ),
        .testTarget(
            name: "TwitterTextEditorTests",
            dependencies: [
                "TwitterTextEditor"
            ]
        )
    ]
)
