# Set the title bar, statically and dynamically

## Overview
Each app hard-codes its window title in every native app: `.title = "Ziggy template"` in `native/linux/src/main.zig` and `native/windows/src/main.zig`, and `newWindow.title = "Ziggy template"` in the macOS `AppDelegate.swift`. Nothing can change the title while the app runs. This plan gives the app declaration a `.title` that every desktop native app asks the core for when it creates its window, and lets the frontend (`window.ziggy.setTitle(text)`) and Zig code on the main thread (`services.setTitle(io, allocator, text)`) change it at any time. Ziggy, its template and test app, both examples and Photosphere move onto it.

## Issues

## Steps

1. **The app declaration's title.** In `packages/ziggy/core/src/lib/app.zig`, add a required `title` field to `App` (in `app_fields`) and `title: []const u8` to `RegisteredApp`, with a comment: the text of the window's title bar when the app starts. Update the field list in `App`'s compile error and doc comment. Add `.title` to every `App(...)` in Ziggy's tests (`packages/ziggy/core/src/test/*.zig`, `helpers.zig`). Run `zig build test --summary all`.

2. **Give the native app the starting title.** Add `const char *ziggy_title(void *handle, size_t *length);` to `packages/ziggy/core/src/lib/ziggy.h` and export it from `packages/ziggy/core/src/lib/ziggy-api.zig`, as `ziggy_menu_json` is: it gives `app.title`. Add a unit test beside the existing `ziggy_menu_json` test.

3. **The set-title call.** In `packages/ziggy/core/src/lib/native-message.zig`, add `set_title: []const u8` to `Call` (no result), written as `{"type":"set-title","title":...}` in `encode` and read back in `parse`. Add a round-trip test to the native message tests.

4. **Zig sets the title.** In `packages/ziggy/core/src/lib/services.zig`, add `setTitle(io, allocator, title)` to `HandlerServices`. `MainServices` in `core.zig` posts the `set_title` call to the native app. On a phone (`isPhone()`), which has no title bar, it returns `error.NoTitleBar` so a caller is never told it worked. Update `fake-native-app.zig` to record `set-title` calls like the other calls, and add tests: a handler calling `setTitle` reaches the fake native app as a `set-title` call, and on a phone config it returns `error.NoTitleBar`.

5. **The frontend sets the title.** Add the system message `set-title` (`packages/ziggy/core/src/lib/system-messages/set-title.zig`, data `{ title: string }`), registered in `system-messages.zig` and `runSystem` in `core.zig`, which calls `services.setTitle`. Add `setTitle(title)` to `window.ziggy` in `packages/ziggy/core/src/lib/ziggy-inject.js` and to `IZiggyBridge` in `packages/ziggy/frontend/src/ziggy-bridge.ts`. Tests: the system message reaches the fake native app as a `set-title` call; `packages/ziggy/frontend/src/test/ziggy-inject.test.ts` checks `setTitle` sends the message.

6. **Linux native app.** In `packages/ziggy/native/linux/src/lib/native-app.zig`, remove `title` from `AppConfig`. After `ziggy_create`, set the window title from `ziggy_title`. Handle the `set_title` call with `gtk_window_set_title`. Add a test-hook-only `window-title` call (step 9) answered with the window's current title (`gtk_window_get_title`, declared in `gtk.zig`).

7. **Windows native app.** In `packages/ziggy/native/windows/src/lib/native-app.zig`, remove `title` from its app config, create the window with the title from `ziggy_title`, handle `set_title` with `SetWindowTextW` and answer `window-title` with `GetWindowTextW`. Run its tests and the Windows compile check.

8. **macOS and the phones.** In `packages/ziggy/native/macos/Sources/ZiggyNativeMacOS/ZiggyBridge.swift`, give the bridge the window (a `window` property the app sets), set its title from `ziggy_title` in `start()`, handle `set-title` by setting `window.title`, and answer `window-title`. The iOS and Android native apps get no `set-title` call (step 4); if one arrives, `ZiggyBridge.fail` (iOS) and the Android equivalent fail loudly naming it.

9. **Test hook.** In `packages/ziggy/core/src/lib/test-control.zig`, add the test command `window-title`, built only with the test hooks, which posts a `window_title` call (added to `Call` in step 3's file, test hooks only) and replies with the title. Add `window_title` to `smoke-tests/lib/common.sh` and its `.md`.

10. **Template, test app and examples.** Add `.title = "Ziggy template"` / `"Ziggy test app"` / `"Ziggy Vite example"` / `"Ziggy Rsbuild example"` to each `backend/src/app.zig`. Remove the hard-coded titles from each app's `native/linux/src/main.zig`, `native/windows/src/main.zig` and macOS `AppDelegate.swift` (setting `bridge.window` instead). Give the test app a button `set-title` in `apps/ziggy-test-app/frontend` that calls `window.ziggy.setTitle("Title from the page")` and a message `set-title-from-zig` whose handler calls `services.setTitle(..., "Title from Zig")`. Run each app's `zig build test`, `bun run compile` and `bun run test`.

11. **Photosphere.** In the Photosphere worktree, add `.title = "Photosphere"` to `apps/photosphere/core/src/app.zig` and remove the hard-coded titles from `apps/photosphere/native/linux/src/main.zig`, the Windows `main.zig` and the macOS `AppDelegate.swift`. Run `bun run tev`.

12. **Smoke test.** Add `smoke-tests/desktop-only/27-title-bar/test.sh`: start the test app, check `window_title` is `Ziggy test app`, click `set-title` and wait for `Title from the page`, send `set-title-from-zig` and wait for `Title from Zig`. List it in `smoke-tests/run.md`. Run Ziggy's `bun run test:everything` and each example's `bun run test:everything`.

13. **Documentation.** In Ziggy, `docs/user-guide/app-declaration.md` gets `title` in the field table; a new section in `docs/user-guide/messages.md` or the frontend guide documents `window.ziggy.setTitle` and `services.setTitle`, and that phones have no title bar; `docs/development/architecture.md` lists the `set-title` call and `ziggy_title`. Update the examples' READMEs where they describe the app declaration.

## Unit Tests
- `App` requires `.title` and records it.
- `ziggy_title` gives the declared title.
- `native-message` encodes and parses `set-title` (and `window-title`).
- `HandlerServices.setTitle` posts a `set-title` call; on a phone it returns `error.NoTitleBar`.
- The `set-title` system message calls `setTitle`.
- `window.ziggy.setTitle` sends the `set-title` system message.
- The Linux and Windows native apps' call handling for `set-title` and `window-title` where their tests can reach it.

## Smoke Tests
- `27-title-bar` on Linux (and on Windows and macOS when run there): starting title from the declaration, changed from the page, changed from Zig.

## Verify
- Ziggy `bun run test:everything` passes, including `27-title-bar`.
- Both examples' `bun run test:everything` pass.
- Photosphere `bun run tev` passes.
- No native app source still contains a hard-coded window title.

## Notes
- The title is in the app declaration because the human chose that. The name and version are separate: they come from `build.zig.zon` (the logging work).
- Phones have no title bar, so `setTitle` fails there with `error.NoTitleBar` rather than pretending to work.
- The plan was written without fresh research, at the human's request. Step 8's macOS bridge changes and the Windows details should be checked against the code when implementing.
