// swift-tools-version:5.7

import PackageDescription

// Ziggy's Apple shells as one Swift package at the root of the repository, which is where Swift Package Manager looks for a package
// it fetches from a git URL. An app that takes Ziggy from a version tag adds this repository as a package and links the product for
// its platform: ZiggyShellMacOS for a MacOS app, ZiggyShellIOS for an iOS app. An app that takes Ziggy from a checkout adds
// packages/ziggy/native/macos or packages/ziggy/native/ios as a local package instead; those hold the same sources. The Zig static
// library (the app's core) is linked by the app's project, not by this package. See docs/integrating-ziggy.md.
let package = Package(
    name: "Ziggy",
    platforms: [
        .macOS(.v11),
        .iOS(.v14),
    ],
    products: [
        .library(
            name: "ZiggyShellMacOS",
            targets: ["ZiggyShellMacOS"]
        ),
        .library(
            name: "ZiggyShellIOS",
            targets: ["ZiggyShellIOS"]
        ),
    ],
    targets: [
        // The C interface of the core (ziggy.h). The MacOS and iOS packages each hold a copy, and the two are the same.
        .systemLibrary(
            name: "CZiggy",
            path: "packages/ziggy/native/macos/Sources/CZiggy"
        ),
        .target(
            name: "ZiggyShellMacOS",
            dependencies: ["CZiggy"],
            path: "packages/ziggy/native/macos/Sources/ZiggyShellMacOS"
        ),
        .target(
            name: "ZiggyShellIOS",
            dependencies: ["CZiggy"],
            path: "packages/ziggy/native/ios/Sources/ZiggyShellIOS"
        ),
    ]
)
