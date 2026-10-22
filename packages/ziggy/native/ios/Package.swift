// swift-tools-version:5.7

import PackageDescription

// Ziggy's native app code for iOS: owns the WKWebView, injects window.ziggy, and moves messages between the frontend and the
// Zig core through the C interface in ziggy.h. The app's own Zig static library, which holds the core, is linked by the app
// project, not by this package.
let package = Package(
    name: "ZiggyNativeIOS",
    platforms: [
        .iOS(.v14),
    ],
    products: [
        .library(
            name: "ZiggyNativeIOS",
            targets: ["ZiggyNativeIOS"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CZiggy",
            path: "Sources/CZiggy"
        ),
        .target(
            name: "ZiggyNativeIOS",
            dependencies: ["CZiggy"]
        ),
    ]
)
