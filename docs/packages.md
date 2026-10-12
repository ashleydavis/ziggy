# Packages

Ziggy is in `packages/ziggy`, in three sides: the UI, the core and the native app. Each part is built in the language and by the build tool its platform needs.

| Side | Name | Subdirectory | Language | What it holds | How an app uses it |
|---|---|---|---|---|---|
| UI | `ziggy-ui`, the only npm package | [`packages/ziggy/ui`](../packages/ziggy/ui) | TypeScript | The types of `window.ziggy`, the JSON types and the types of the task events the core sends | `import type { ITaskCompletedEvent } from "ziggy-ui"` |
| Core | `ziggy-core` | [`packages/ziggy/core`](../packages/ziggy/core) | Zig, with C headers (`ziggy.h`, `jni-c.h`) and JavaScript (`ziggy-inject.js`) | The C interface, the message dispatcher, the task runner, the origin check, the host callback plumbing, the test hooks, the task queue and the helpers it is written with, and `ziggy-inject.js`, the script that creates `window.ziggy`, which the core embeds so an app supplies nothing for it | `@import("ziggy-core")` |
| Native app, Linux | `ziggy-native-linux` | [`packages/ziggy/native/linux`](../packages/ziggy/native/linux) | Zig, with a C header (`c.h`) | The GTK 3 and WebKitGTK 4.1 host | Built by the app's `build.zig` |
| Native app, Windows | `ziggy-native-windows` | [`packages/ziggy/native/windows`](../packages/ziggy/native/windows) | Zig, with a C header (`c.h`) | The WebView2 host | Built by the app's `build.zig` |
| Native app, MacOS | `ZiggyNativeMacOS` | [`packages/ziggy/native/macos`](../packages/ziggy/native/macos) | Swift | The WKWebView host, as a Swift package | Linked by the app's Xcode project |
| Native app, iOS | `ZiggyNativeIOS` | [`packages/ziggy/native/ios`](../packages/ziggy/native/ios) | Swift | The WKWebView host, as a Swift package | Linked by the app's Xcode project |
| Native app, Android | `dev.ziggy.nativeapp`, Gradle `ziggy-native-android` | [`packages/ziggy/native/android`](../packages/ziggy/native/android) | Java, built by Gradle | The Android WebView host, as a Gradle library. Its native methods are implemented in the core. | A dependency of the app's Gradle project |

Each native app hosts the system web view, draws the menu, handles shortcuts and developer tools, shows the file and folder dialogs and moves messages between the UI and the core.

The test of `ziggy-inject.js` is in `ziggy-ui` (`packages/ziggy/ui/src/test/ziggy-inject.test.ts`), which reads the script from the core.

Two files at the root of the repository build these:

- `build.zig`: builds Ziggy, runs its tests and holds the functions an app's own `build.zig` calls to build its core and its Linux and Windows native apps. Its helpers are in `build/`.
- `Package.swift`: the MacOS and iOS native apps as one Swift package, for an app that takes Ziggy from a version tag.
