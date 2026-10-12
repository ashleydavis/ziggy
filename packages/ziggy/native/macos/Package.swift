// swift-tools-version:5.7

import PackageDescription

// Ziggy's shell code for MacOS: owns the WKWebView, injects window.ziggy, and moves messages between the UI and the Zig
// core through the C interface in ziggy.h. The app's own Zig static library, which holds the core, is linked by the app
// project, not by this package.
let package = Package(
    name: "ZiggyNativeMacOS",
    platforms: [
        .macOS(.v11),
    ],
    products: [
        .library(
            name: "ZiggyNativeMacOS",
            targets: ["ZiggyNativeMacOS"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CZiggy",
            path: "Sources/CZiggy"
        ),
        .target(
            name: "ZiggyNativeMacOS",
            dependencies: ["CZiggy"]
        ),
    ]
)
