# Ziggy template, MacOS native app

An AppKit app: a window holding Ziggy's `WKWebView`, under the backend's menu. All the Ziggy behaviour is in the `ZiggyNativeMacOS` Swift package (`packages/ziggy/native/macos`), which the project references as a local package. The window accepts `-geometry=WxH` (the position is ignored). Terms are defined in [Ziggy's glossary](https://github.com/ashleydavis/ziggy/blob/main/docs/glossary.md).

## Web view API used

`WKWebView`, `WKUserScript` (document start, main frame), `WKScriptMessageHandler` named `ziggy`, `evaluateJavaScript`, `WKURLSchemeHandler` (which serves the bundled UI), `WKNavigationDelegate`, `WKUIDelegate` and `NSWorkspace.open` for external links.

## Building

The project links `libziggy_template.a` from the directory in the `ZIGGY_NATIVE_DIR` build setting (default `zig-out` beside the project) (which has the UI embedded in it, so the app has no UI files of its own). Fill that directory first with `scripts/sync-macos.sh`. The build and run scripts (`build-macos.sh`, `run-macos.sh`, `package-macos.sh`, `open-macos.sh`, `clean-macos.sh`) do it for you.

## What you do on the Mac

- Install Xcode 14.2 (macOS 12.7.6 is enough) and `jq`, and run `mise install` in the repository, `bun install` at the root.
- Run `bun run run:macos`.

## Menu, shortcuts and developer tools

The native app draws the backend's menu (`ziggy_menu_json`, made at compile time from the `ziggy.menu.Menu` in `backend/src/lib/menu.zig`) as the application's main menu. The app delegate creates no menu of its own.

- The application menu comes first: About and Quit. The backend's own Quit and About items are not drawn again in their menus: they become the application menu's items, with the shortcut the backend gave (Command+Q when there is none). A menu left empty by that is not shown, and `[]` adds nothing extra.
- Each item's shortcut is parsed by `ziggy_parse_accelerator` and set as the item's key equivalent and modifier mask, so shortcuts work while the web view has the focus. "plus" is `+` (so Command and plus; whether Command and `=` also triggers it is untested).
- The native app does these actions itself: quit, close-window, reload, toggle-devtools, toggle-fullscreen, zoom-in, zoom-out, zoom-reset (`pageZoom`, steps of 0.1, limits 0.3 to 5.0) and focus-window (restore the window and bring it to the front). It also does undo, redo, cut, copy, paste and select-all, which go to the first responder as `undo:`, `redo:`, `cut:`, `copy:`, `paste:` and `selectAll:`. Every other action is the name of one of the app's own menu items and is posted to the backend as `{"kind":"system","name":"menu-action","data":{"action":"..."}}`, a system message. The core runs the item.
- Developer tools are on in release builds too. `developerExtrasEnabled` is set on the web view's preferences (gives Inspect Element in the context menu), and `isInspectable` is set where the toolchain's SDK has it (macOS 13.3 and later, so not in a build with Xcode 14.2). The Toggle Developer Tools item uses the private WebKit interface `-[WKWebView _inspector]` with `isVisible`, `show` and `hide`, because there is no public call that opens the inspector on these SDKs. If a selector is missing the app prints a message to standard error and Inspect Element still works. Apple may reject an app that uses a private interface from the App Store, which matters only if this is ever distributed there.
- None of this was compiled or run. It was written on Linux against the AppKit and WebKit APIs from memory of the Xcode 14.2 SDKs.

The iOS native app shows no menu: the menu code is compiled for macOS only.

## File and directory pickers

The pick-files, pick-folder and pick-file messages open `NSOpenPanel` (files, or a directory) and `NSSavePanel` through the package's `pick_paths` callback, on the main thread with `runModal`. Cancelling gives no paths. Not compiled or run. See the package README.

## Choosing a menu item from a test

In a test hooks build the backend can choose a menu item by action through the `menu_action` callback (the control connection's `menu` command). The native app copies the action, moves to the main thread and runs `ZiggyMenu.perform(action:)`, the same function a click on the item runs for every action the native app owns, so a test runs what a click runs. An action the native app does not own goes to the backend as a menu-action system message, whatever it is. iOS leaves the callback unset.

- The edit actions (undo, redo, cut, copy, paste, select-all) normally reach the web view because a click leaves it first responder. A test choice first makes the window key and the web view first responder (`makeKeyAndOrderFront`, `makeFirstResponder`), then sends the selector to the responder chain with `sendAction(_:to: nil:from:)`. If nothing handles the selector, the native app prints that to standard error. Whether WKWebView handles `undo:` and `redo:` is untested.
- The window sets `.fullScreenPrimary` so toggle-fullscreen works. The change animates, so a test should wait for the UI's size to settle.
- Zoom uses `pageZoom`, which changes the UI's viewport size like browser zoom does.
- The developer tools toggle uses the private inspector. Whether it docks inside the window (which shrinks the UI's viewport height) or opens a separate window is untested and may depend on a saved inspector setting.
- Quit calls `NSApplication.terminate`, which runs `applicationWillTerminate` (destroying the backend) and ends the process. It would wait if a modal panel were open.

Dropped files are read from the drag pasteboard by the web view subclass in ZiggyNativeMacOS.
