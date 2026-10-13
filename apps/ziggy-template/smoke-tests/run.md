# run.sh

Runs the Ziggy template's smoke test scenarios for one platform. Invoked by the root `package.json` scripts `test:ziggy-template`, `test:ziggy-template:and`, `test:ziggy-template:ios` and `test:ziggy-template:dev`, never directly.

## Arguments

- `<platform>`: `linux`, `windows`, `macos`, `android` or `ios` (a connected iPhone or iPad when there is one, see `lib/ios-device.sh`, otherwise a simulator), or `dev` for dev mode: the dev host in front of Vite's dev server, with the UI in a headless Chrome or Chromium, on Linux, Windows (Git Bash) or macOS. The browser is the first of `google-chrome`, `chromium` and `chromium-browser` on the PATH, or Chrome where its installer puts it on macOS and Windows, and `ZIGGY_DEV_BROWSER` names another. Each has a platform library in `lib/<platform>.sh` that builds the app, starts it and stops it.
- `[scenario]`: optional scenario number or name, to run one scenario.

## Behaviour

Builds the template twice for the platform, once with the test hooks and once without. Then runs each scenario's `test.sh`, one after another, giving each its own temporary directory and a held-to timeout. A scenario drives the running app through the test control connection (see `lib/common.sh` for what a scenario can do and what a platform library implements). Every process started is recorded as it is launched, and any still running at the end fails the run and is stopped.

## Scenarios

- `1-reply`: the UI loads and the Zig core answers a request.
- `2-short-task`: a short task sends output and progress and its job goes away.
- `3-long-task-with-children`: a long task queues children and waits for them while the UI stays responsive.
- `4-cancel-long-task`: cancelling a source stops its task early.
- `5-cancel-one-of-several-sources`: cancelling one source leaves the other tasks running.
- `6-edges`: a large payload, text with quotes and non-ASCII characters, an error reply, a failing task, a file in the data directory and the native host callback.
- `7-control-reports-bad-commands`: the control connection answers a line that is not a command with an error and keeps working.
- `8-release-has-no-hooks`: the release build has no control connection.
- `9-quit-ends-everything`: quitting with tasks running ends the app and everything it started.
- `10-pickers`: the file and folder buttons show what the dialogs return, several files, a folder, a save location and a cancel. The scenario answers each dialog through the control connection, so no native dialog is shown.
- `16-media-server`: the UI loads an image and a video from the loopback HTTP server in the template's core, and asks it for a range of bytes. The video is read to its metadata only, because the Android emulator's software video decoding crashes the emulator.
- `17-ui-storage`: a value the UI writes to `localStorage` and to IndexedDB is still there after the app is quit and started again. It waits before the restart because Android's web view writes `localStorage` to disk a few seconds after the UI sets it.
- `18-keep-alive-survives-leaving`: on a phone, a keep-alive background task goes on counting in a file in the data directory when the app is sent to the background, and on Android the foreground service is running. On a desktop, closing the window quits the app even with a keep-alive task running, and the scenario checks the app ends.
- `21-app-facilities`: the parts of Ziggy an app's own core code uses beyond channels and tasks: an error the app describes in a sentence, a task that reads its id, type, source, child limit and the app's state from its context, a task that runs children one after another and stops when cancelled, a task queued and a task cancelled from the app's code, an event the app sends to the UI, the counts the app keeps by observing tasks end and send messages and the UI removing its listeners for an event.

The scenarios in `desktop-only` run on Linux, Windows and macOS and not on a phone, because the menu is a desktop feature. They choose menu items through the control connection's `menu` command, which calls the native app's own function for the item, the one a click runs, so the native app's actions really happen:

- `11-menu-ui-actions`: About, and the items that start and cancel tasks, do what their buttons do.
- `12-menu-view`: Reload starts the UI afresh, and the zoom items change the size of the area the UI is drawn in.
- `13-menu-edit`: Select All, Cut, Paste, Copy, Undo and Redo edit the UI's text area.
- `14-menu-quit`: Quit ends the app and everything it started, with tasks running.
- `15-menu-devtools`: Toggle Developer Tools opens and closes the developer tools, seen the way each platform shows them.
- `19-normal-task-ends-with-window`: closing the window with only a normal background task running ends the app.
- `20-drop-files`: a file dropped on the window gets its real path from `getPathForFile`, and a file of another size does not. The drop is faked in two steps, because no tool can drag a file into the window: the `drop` command records it with the core and `drop-file` gives the UI a drop event. The native app's own reading of a real drop is tested by hand.

The scenarios in `dev-only` run in dev mode only:

- `22-hot-reload`: the supervisor starts Vite, builds the dev host and starts it in front of Vite, a saved UI file reaches the page through Vite's reload, passed through the dev host, and a saved Zig file rebuilds and restarts the dev host on the same port and the page reconnects to the new core. It edits a copy of the template made in the template's `tmp`, so no other run's files change.
- `23-drop-files`: a file dropped on the page reaches the UI with the path of the copy the dev host saved, holding the file's contents, and only one copy is made.

In dev mode the other scenarios run against the dev host in front of Vite, and the ones that need something only a native app has (a window, the menu) are the `desktop-only` ones, which dev mode does not run. `18-keep-alive-survives-leaving` closes the page there, and the dev host goes on running the task.

Toggle Full Screen is not smoke tested. The Linux suite runs on a virtual display with no window manager, and nothing honours a request for full screen there, so there is nothing to see change.

## Building on Android

The Android library builds the test APK and the release APK one after the other through the one Gradle project and synced library directory of the checkout. Two runs building at the same time would swap the library under each other, so `ziggy_platform_prepare` in `lib/android.sh` holds a lock file inside that build directory for the whole build. A second run waits for the first to finish building, then builds its own.
