# run.sh

Runs the Ziggy test app's smoke test scenarios for one platform. Invoked by the root `package.json` scripts `test:smoke`, `test:smoke:android`, `test:smoke:ios` and `test:smoke:dev`, never directly. Terms are defined in [Ziggy's glossary](https://github.com/ashleydavis/ziggy/blob/main/docs/glossary.md).

## Arguments

- `<platform>`: `linux`, `windows`, `macos`, `android` or `ios` (a connected iPhone or iPad when there is one, see `lib/ios-device.sh`, otherwise a simulator), or `dev` for dev mode: the dev backend in front of Vite's dev server, with the frontend in a headless Chrome or Chromium, on Linux, Windows (Git Bash) or macOS. The browser is the first of `google-chrome`, `chromium` and `chromium-browser` on the PATH, or Chrome where its installer puts it on macOS and Windows, and `ZIGGY_DEV_BROWSER` names another. Each has a platform library in `lib/<platform>.sh` that builds the app, starts it and stops it.
- `[scenario]`: optional scenario number or name, to run one scenario.

## Behaviour

Builds the test app twice for the platform, once with the test hooks and once without. Then runs each scenario's `test.sh`, one after another, giving each its own temporary directory and a held-to timeout. A scenario drives the running app through the test control connection (see `lib/common.sh` for what a scenario can do and what a platform library implements). Every process started is recorded as it is launched, and any still running at the end fails the run and is stopped.

## Scenarios

- `1-reply`: the frontend loads and the backend sends a message response.
- `2-short-task`: a short task sends output and progress and its job goes away.
- `3-long-task-with-children`: a long task queues children and waits for them while the frontend stays responsive.
- `4-cancel-long-task`: cancelling a source stops its task early.
- `5-cancel-one-of-several-sources`: cancelling one source leaves the other tasks running.
- `6-edges`: a large payload, text with quotes and non-ASCII characters, an error message response, a failing task, a file in the data directory and the native call.
- `7-control-reports-bad-commands`: the control connection replies to a line that is not a command with an error and keeps working.
- `8-release-has-no-hooks`: the release build has no control connection.
- `9-quit-ends-everything`: quitting with tasks running ends the app and everything it started.
- `10-pickers`: the file and directory buttons show what the dialogs return, several files, a directory, a save location and a cancel. The scenario supplies each dialog's result through the control connection, so no native dialog is shown.
- `16-media-server`: the frontend loads an image and a video from the loopback HTTP server in the test app's backend, and fetches a range of bytes with a `Range` header. The video is read to its metadata only, because the Android emulator's software video decoding crashes the emulator.
- `17-ui-storage`: a value the frontend writes to `localStorage` and to IndexedDB is still there after the app is quit and started again. It waits before the restart because Android's web view writes `localStorage` to disk a few seconds after the frontend sets it.
- `18-keep-alive-survives-leaving`: on a mobile device, a keep-alive background task goes on counting in a file in the data directory when the app is sent to the background, and on Android the foreground service is running. On a desktop, closing the window quits the app even with a keep-alive task running, and the scenario checks the app ends.
- `21-app-own-code`: the parts of Ziggy an app's own backend code uses beyond messages and tasks: an error the app describes in a sentence, a task that reads its id, type, source and child limit from its context, a task that runs children one after another and stops when cancelled, a task queued and a task cancelled from the app's code, an event the app sends to the frontend, the app observing tasks end and send events and the frontend removing its listeners for an event.

The scenarios in `native-only` run in a native app on every platform and not in dev mode, where the frontend comes from the dev server:

- `24-ui-address`: the frontend is served from the platform's address (`ziggy-app://app/` on Linux, macOS and iOS, `https://ziggy-app.invalid/` on Windows and Android), the page is a secure context, and `localStorage`, IndexedDB, and `fetch` and `XMLHttpRequest` of the frontend's own files work there.

The scenarios in `desktop-only` run on Linux, Windows and macOS and not on a mobile device, because the menu is a desktop feature. They choose menu items through the control connection's `menu` command, which calls the native app's own function for the item, the one a click runs, so the native app's actions really happen:

- `11-menu-ui-actions`: About, and the items that start and cancel tasks, do what their buttons do.
- `12-menu-view`: Reload starts the frontend afresh, and the zoom items change the size of the area the frontend is drawn in.
- `13-menu-edit`: Select All, Cut, Paste, Copy, Undo and Redo edit the frontend's text area.
- `14-menu-quit`: Quit ends the app and everything it started, with tasks running.
- `15-menu-devtools`: Toggle Developer Tools opens and closes the developer tools, seen the way each platform shows them.
- `19-normal-task-ends-with-window`: closing the window with only a normal background task running ends the app.
- `20-drop-files`: a file dropped on the window gets its real path from `getPathForFile`, and a file of another size does not. The drop is faked in two steps, because no tool can drag a file into the window: the `drop` command records it with the backend and `drop-file` gives the frontend a drop event. The native app's own reading of a real drop is not covered by any automatic test.
- `25-close-with-dialog-open`: quitting while a real file dialog is open ends the app. Nothing reports that the dialog is on screen, so the scenario waits a few seconds after the click before it quits.

The scenarios in `dev-only` run in dev mode only:

- `23-drop-files`: a file dropped on the page reaches the frontend with the path of the copy the dev backend saved, holding the file's contents, and only one copy is made.

In dev mode the other scenarios run against the dev backend in front of Vite, and the ones that need something only a native app has (the address it serves the frontend from, a window, the menu) are the `native-only` and `desktop-only` ones, which dev mode does not run. `18-keep-alive-survives-leaving` closes the page there, and the dev backend goes on running the task.

Toggle Full Screen is not smoke tested. The Linux suite runs on a virtual display with no window manager, and nothing honours a request for full screen there, so there is nothing to see change.

## Building on Android

The Android library builds the test APK and the release APK one after the other through the one Gradle project and synced library directory of the checkout. Two runs building at the same time would swap the library under each other, so `ziggy_platform_prepare` in `lib/android.sh` holds a lock file inside that build directory for the whole build. A second run waits for the first to finish building, then builds its own.
