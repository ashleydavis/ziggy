# Ziggy package

The package an app is built on: a Zig core with its task queue, a native host for each platform that shows the system web view and the TypeScript types of `window.ziggy` for the UI. The UI is TypeScript, and everything else is Zig. Nothing in this folder names an app.

- `core/`: the core library every app links, `ziggy-core`, imported as `@import("ziggy-core")`. It has the C interface (`core/src/lib/ziggy.h`), the message dispatcher, the task runner, the origin check, the host callback plumbing, the test control connection, the task queue and the helpers it is written with, and `ziggy-inject.js`, the script every native app injects to create `window.ziggy` (embedded in the core, so an app supplies nothing for it).
- `ui/`: the `ziggy-ui` package, the TypeScript types of `window.ziggy` and of the messages the core sends.
- `native/<platform>/`: the part of each native app that Ziggy provides: `linux` (Zig, GTK 3, WebKitGTK 4.1), `windows` (Zig, WebView2), `macos` and `ios` (Swift packages, WKWebView) and `android` (a Java library and Gradle build of its own, with the native methods in the core's `jni.zig`).
- `dev/`: dev mode: the dev host, which runs an app's core for a UI in an ordinary browser served by the app's bundler, and the supervisor that rebuilds it as the app's Zig files change. No native app and no release build includes it. See its [README](dev/README.md).

The [README at the root of the repository](../../README.md) has the guides: how an app uses this package, how an app is built and distributed, how Ziggy is released and the architecture.
