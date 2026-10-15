# ZiggyNativeIOS

Ziggy's native app code for iOS, as a Swift package (swift-tools-version 5.7, iOS 14). One class, `ZiggyBridge`, serves the app. Terms are defined in the [glossary](../../../../docs/glossary.md).

- `CZiggy` is a system library target whose `ziggy.h` is a link to the backend's own header (`packages/ziggy/core/src/lib/ziggy.h`).
- `ZiggyNativeIOS` owns the `WKWebView`, injects `ziggy-inject.js` at document start, forwards UI messages to `ziggy_post_message`, delivers the backend's messages on the main thread in order (`window.__ziggyReceive(<json>)`), decides every navigation with `ziggy_check_url` and creates and destroys the backend.

The static library with the backend (`libziggy_template.a` for the template) is linked by the app project.

## Using it

```swift
let bridge = ZiggyBridge(frame: frame)  // web view, injected script, message handler
// put bridge.webView on screen
bridge.start()                          // creates the backend and loads the UI, which the backend serves
// when the app ends:
bridge.shutdown()                       // ziggy_destroy, once
```

The UI and the script that exposes `window.ziggy` (`ziggy-inject.js`, from `packages/ziggy/core/src/lib`) are both embedded in the app's backend library, so the app bundle holds neither.

## Test hooks

When the linked library has the test hooks and `ZIGGY_TEST_MODE` is set, the native app starts the control connection and writes its port to the file named by `ZIGGY_TEST_PORT_FILE`.

## Failures

A failure that leaves the app unusable prints to standard error and exits non-zero. A UI that fails to load, a blocked navigation and a failed delivery print to standard error and the app carries on.

## Keeping the app running

The backend's `keep_alive` callback reaches `ZiggyBridge`, which takes a background task assertion (`beginBackgroundTask`) while tasks the app must be kept running for are queued or running, and gives it back when they end. The system ends the assertion after a limited time, and the app is suspended then.

## File pickers

`ZiggyPicker.swift` backs the backend's `pick_paths` callback. The backend calls it from a worker thread. The dialog is shown on the main thread and the worker waits on a `DispatchSemaphore`, so the main thread never blocks on it. The result is a JSON array of paths, `[]` when the user cancelled. A failure (no window, a buffer too small, an unknown kind) prints to standard error and returns a negative number.

`UIDocumentPickerViewController` is presented over the web view's window, with the delegate's callbacks (including cancel) giving the result.

- Open files uses `forOpeningContentTypes: [.item], asCopy: true` with multiple selection. The paths are copies in the app's temporary directory, which the app can read and write freely until the system clears that directory. The originals are untouched.
- Directory uses `forOpeningContentTypes: [.folder]`. The native app calls `startAccessingSecurityScopedResource` on the directory and keeps access for the rest of the process, so the directory's path and everything inside it can be listed, read and written. A path from an earlier run, or a path inside the directory used after the app restarts, is denied until the user picks the directory again, because keeping access across runs needs a bookmark.
- Save: iOS has no dialog for choosing where to save a file, so the callback fails and the backend sends an error message response for the message.

A loopback server the UI loads media from needs `NSAllowsLocalNetworking` in the app's `Info.plist`.

## The app's own native calls

The app's own native calls are how the backend has the app's own code do something only the platform can do (a permission prompt, the keychain, a share sheet), named by a method. The app gives `ZiggyBridge.setHostRequestHandler` an object that conforms to `ZiggyHostRequestHandler` before `start`. The backend calls it from a worker thread with the method name and the JSON text of its argument, and the handler returns the JSON text of the result or throws `ZiggyHostRequestError` with a reason in words the user can act on. The handler may block, for instance on a permission dialog, because the backend's worker thread waits and the main thread does not. The native app knows no method names. With no handler set the backend has no `host_request` native call, and such a call fails with a message saying so.

## Starting work from the app

When the system wakes the app with no UI on screen (a background task, for instance) the app starts work in the backend itself. `ZiggyBridge.request(channel:data:completion:)` sends a message as the UI's `invoke` does, and its message response goes to the completion and not to the UI. `ZiggyBridge.send(channel:data:)` is the one-way form. `keepRunningChanged` is called on the main thread each time the backend says the app must be kept running or no longer must be.
