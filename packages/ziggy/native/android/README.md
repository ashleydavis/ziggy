# Ziggy shell for Android

Ziggy's Android framework code: a Java library (no Kotlin) that is a Gradle build of its own. An app's Gradle project takes it as the dependency `dev.ziggy:ziggy-shell-android`, built from a Ziggy checkout (`includeBuild` in the app's `settings.gradle`) or from a version tag of Ziggy's repository (a source dependency). The exact lines are in the guide to integrating Ziggy. It sets its own SDK levels (`compileSdkVersion` 35, `minSdkVersion` 24) and uses the same Android Gradle plugin version an app must use, because Gradle does not allow two versions of that plugin in one build.

`ZiggyShell` takes an activity and a `WebView` and:

- Configures the web view: JavaScript and DOM storage on (so `localStorage` and IndexedDB work; `localStorage` reaches the disk a few seconds after the UI sets it); file access, file-URL access, content access and universal access off (the bundled UI is answered from the core library through `shouldInterceptRequest`, so it needs no file access); no cleartext or mixed content.
- Injects `ziggy-inject.js` (embedded in the core library, so the app supplies nothing) with `WebViewCompat.addDocumentStartJavaScript` (androidx.webkit), so it runs before the UI's own scripts. There is no fallback: a web view without that feature makes `start` throw, because running the script when the UI starts loading races the UI's first script and would lose quietly.
- Exposes `window.ZiggyAndroid.postMessage(string)` with `addJavascriptInterface`, which the injected script posts through.
- Delivers core messages with `evaluateJavascript("window.__ziggyReceive(<json>);")` on the main thread, in the order they arrived. The core delivers from any thread, so each message is copied and posted to the main looper.
- Decides every navigation with the core's origin check: `shouldOverrideUrlLoading` opens http, https and mailto links in the system browser and blocks the rest. A request the UI makes for something (an image, a video, a script request) is not checked, as on every other platform, so the UI can load media from a server on the loopback address. `shouldInterceptRequest` answers the app's own UI from the core library.
- In a test hooks core library, when the launching Intent has the boolean extra `ziggy.testMode`, reads the string extra `ziggy.testPortFile`, and appends `?testMode=1` to the UI's URL.

The activity calls `start` in `onCreate` and `destroy` in `onDestroy`. `destroy` calls the core's destroy once and nothing is delivered after it.

The native methods (`ZiggyNative`) are implemented in Zig, in `packages/ziggy/core/src/lib/jni.zig`, which the app's core library exports with `ziggy.jni.exportJni(...)` for an Android target. The Java side is the web view and the lifecycle, and everything that crosses to the core goes through that file. Messages cross as UTF-8 byte arrays.

The library is built by the app's Gradle build, which includes this one.

## File and folder pickers

The core asks the shell for a picker through the `pick_paths` host callback, from a worker thread. The Zig side (`jni.zig`) calls `ZiggyHost.pickPathsJson(kind, title, initialName)` on that thread, and `ZiggyShell` starts a Storage Access Framework activity with `startActivityForResult` on the main thread and blocks the worker until the activity's `onActivityResult` answers. The activity must forward `onActivityResult` to `ZiggyShell.onActivityResult`. The answer is a JSON array of strings, as UTF-8 bytes, and `[]` when the user cancelled.

- Open files: `ACTION_OPEN_DOCUMENT`, openable, any type, multiple allowed. Each chosen document is copied into its own directory under the app's cache directory (`ziggy-picked/<unique>/<display name>`) and the answer is those file system paths, so the UI and the core get real paths. The copies are not deleted by Ziggy; the cache directory is the system's to clear.
- Folder: `ACTION_OPEN_DOCUMENT_TREE`. The answer is the tree Uri string (`content://...`). A tree Uri is not a file system path: Android does not give an app a path to a folder the user picked, only a Uri to read and write through a `ContentResolver`.
- Save: `ACTION_CREATE_DOCUMENT` with the suggested name as `EXTRA_TITLE`. The answer is the document's Uri string, which is also not a file system path.
- The title is ignored: the system pickers have no title to set (`EXTRA_TITLE` is the file name for a save).
- Strings pass to Java with `NewStringUTF`, which uses modified UTF-8, so a title or suggested name with a character outside the basic multilingual plane is not carried correctly. The answer, which can hold any path, crosses as bytes and is exact.
- Cancelling (including the back button) is a normal `[]`. A failure to show or read a picker is logged and answered as a failure, which the core reports to the UI. Quitting, or destroying the shell, with a picker open closes the picker and answers `[]`, so the core's workers can stop.

The keep-alive callback starts and stops a foreground service. How it works is in the architecture document. The library's manifest declares the service and its permissions. An app that serves media from a loopback server also needs the `INTERNET` permission and a network security config that allows cleartext to `127.0.0.1`, as the example does.
