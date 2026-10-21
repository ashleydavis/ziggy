# ZiggyNativeMacOS

Ziggy's native app code for MacOS, as a Swift package (swift-tools-version 5.7, macOS 11). One class, `ZiggyBridge`, serves the app. Terms are defined in the [glossary](../../../../docs/glossary.md).

- `CZiggy` is a system library target whose `ziggy.h` is a link to the backend's own header (`packages/ziggy/core/src/lib/ziggy.h`).
- `ZiggyNativeMacOS` owns the `WKWebView`, injects `ziggy-inject.js` at document start, forwards UI messages to `ziggy_post_message`, delivers the backend's messages on the main thread in order (`window.__ziggyReceive(<json>)`), decides every navigation with `ziggy_check_url` and creates and destroys the backend.

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

## Menu and developer tools

After the backend is created `ZiggyBridge.start` reads the menu JSON (`ziggy_menu_json`, which the core makes at compile time from the app's `ziggy.menu.Menu`) and `ZiggyMenu` makes it the main menu: the application menu first (About, Quit), then the app's menus. The backend's Quit and About items become the application menu's items instead of appearing twice. Shortcuts come from `ziggy_parse_accelerator` and become key equivalents with modifier masks, which AppKit runs even when the web view has the focus.

The native app performs quit, close-window, reload, toggle-devtools, toggle-fullscreen, zoom-in, zoom-out, zoom-reset and focus-window (restore the window and bring it to the front) itself. The edit actions (undo, redo, cut, copy, paste, select-all) go to the first responder as the standard selectors. Every other action is the name of one of the app's own menu items and is posted to the backend as `{"kind":"system","name":"menu-action","data":{"action":"<name>"}}`, a system message. The core runs the item: it calls a Zig function or sends the UI the app event `{"type": "menu", "item": "<name>"}`.

Developer tools are on in every build. The `developerExtrasEnabled` preference gives Inspect Element, and `isInspectable` is set under `#if swift(>=5.8)` and `#available(macOS 13.3, *)`, because Xcode 14.2's SDK lacks it. Toggle Developer Tools calls the private WebKit interface `-[WKWebView _inspector]` (`isVisible`, `show`, `hide`), reached by selector name, because no public call opens the inspector programmatically on these SDKs. A missing selector prints a message to standard error.

## File and directory pickers

`ZiggyPicker.swift` backs the backend's `pick_paths` callback. The backend calls it from a worker thread. The dialog is shown on the main thread and the worker waits on a `DispatchSemaphore`, so the main thread never blocks on it. The result is a JSON array of paths, `[]` when the user cancelled. A failure (no window, a buffer too small, an unknown kind) prints to standard error and returns a negative number.

`NSOpenPanel` serves files (multiple selection, no directories) and a directory, and `NSSavePanel` with `nameFieldStringValue` set to the suggested name serves save. The title is both the panel's title and its message. It runs with `runModal` on the main thread, so a quit that arrives while a panel is open waits until the panel closes.

## Dropped files

The web view is a subclass (`ZiggyWebView`) that overrides `performDragOperation`, reads the file paths from the dragging pasteboard, records them with the backend (`ziggy_files_dropped`) and then lets the web view carry on. The inject script gives the UI the paths.

A loopback server the UI loads media from needs `NSAllowsLocalNetworking` in the app's `Info.plist`.
