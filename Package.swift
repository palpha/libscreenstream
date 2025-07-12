// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "screenstream",
    platforms: [.macOS("12.3")],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "screenstream",
            type: .dynamic,
            targets: ["screenstream"]
        ),
        .library(
            name: "ScreenStream",
            targets: ["screenstream"]
        ),
    ],
    targets: [
        .target(
            name: "screenstream"
        )
    ]
)
