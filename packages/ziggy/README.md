# Ziggy package

The package an app is built on: a Zig core, a task queue, a native host for each platform that shows the system web view, and a small TypeScript bridge that gives the page `window.ziggy`. The UI is TypeScript in the page, and everything else is Zig. Nothing in this folder names an app.

- `core/`: the core library every app links, imported as `@import("ziggy")`. It has the C interface (`core/src/lib/ziggy.h`), the message dispatcher, the task runner, the origin check, the host callback plumbing and the test control connection.
- `task-queue/`: the task queue and the helpers it is written with, imported as `@import("task-queue")`.
- `bridge/`: `inject/ziggy-inject.js`, the script every shell injects to create `window.ziggy` (embedded in the core, so an app supplies nothing for it), and its types, the `ziggy-bridge` package.
- `native/<platform>/`: the framework half of each shell: `linux` (Zig, GTK 3, WebKitGTK 4.1), `windows` (Zig, WebView2), `macos` and `ios` (Swift packages, WKWebView) and `android` (a Java library and Gradle build of its own, with the native methods in the core's `jni.zig`).

The [README at the root of the repository](../../README.md) has the guides: how an app uses this package, how an app is built and distributed, how Ziggy is released, and the architecture.
