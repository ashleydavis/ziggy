# Ziggy package

The package an app is built on: a Zig core library with its task queue, a native host for each platform that shows the system web view and the TypeScript types of `window.ziggy` for the frontend. The frontend is TypeScript, and everything else is Zig. Nothing in this directory names an app. Terms are defined in the [glossary](../../docs/glossary.md).

- `core/`: the core library every app links, imported as `@import("ziggy")`. It has the C interface (`core/src/lib/ziggy.h`), the message dispatcher, the task runner, the origin check, the native call plumbing, the test control connection, the task queue and the helpers it is written with, and `ziggy-inject.js`, the script every native app injects to create `window.ziggy` (embedded in the core library, so an app supplies nothing for it).
- `frontend/`: the `ziggy` package, the TypeScript types of `window.ziggy` and of the messages the backend sends.
- `native/<platform>/`: the part of each native app that Ziggy provides: `linux` (Zig, with GTK 3 and WebKitGTK 4.1), `windows` (Zig, WebView2), `macos` and `ios` (Swift packages, WKWebView) and `android` (a Java library and Gradle build of its own, with the native methods in the core library's `jni.zig`).
- `dev/`: dev mode: the dev backend, which runs an app's backend for a frontend in an ordinary browser served by the app's bundler, and the supervisor that rebuilds it as the app's Zig files change. No native app and no release build includes it.

## See also

- [Dev mode](../../docs/development/dev-mode.md): how dev mode works.
- [Ziggy's README](../../README.md): the guides to using this package, building and distributing an app and how Ziggy is released.
