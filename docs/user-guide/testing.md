# Testing your app

Terms are defined in the [glossary](../glossary.md).

An app has unit tests for its frontend (`frontend/src/test`) and its backend (`backend/src/test`), and smoke tests (`smoke-tests`) that start the real app and drive it from outside. The scripts that run them are in [Scripts](scripts.md).

## Test hooks

A smoke test cannot click a native file dialog, read what the web view shows or wait for the frontend to finish loading, so the app offers a way in: the test hooks.

- The remote control code is in every build. It does nothing unless the app is started with `--remote-control <host:port>`. On Android the address is the string Intent extra `ziggy.remoteControl`.
- Test mode is on exactly when the app is started that way. The template's backend tells the frontend through the `testMode=1` query parameter.
- A test sets up its state from outside the app, with config files and data placed on disk, wherever it can.
- A smoke test sets `<NAME>_CONFIG_DIR` and `<NAME>_STATE_DIR` for the app's config and state files, on every platform, so one run's files are never another's. See [where the config file lives](config-file.md#where-it-lives) and [where the state file lives](state-file.md#where-it-lives).
- A smoke test starts the app with `--theme light|dark|system` by setting `ZIGGY_THEME`, which the platform library adds to the command line (the `ziggy.theme` extra on Android). See [Theme](theme.md).
- Add a hook of the app's own only where nothing outside the app can do the job.

The native apps take `--remote-control` and its address out of the command line.

## The remote control connection

The app connects out to the remote control server at the address it was given. It opens one WebSocket connection to `ws://<host:port>/`, on a thread of its own. When the connection cannot be made, the app prints the address and fails to start.

The [remote control server](../../tools/remote-control-server/README.md) is a separate program, `ziggy-remote-control-server`, which an app gets from the Ziggy repository as a dev dependency. It listens on one port for the app and on another for the test script. It passes each line the script writes to the app as one WebSocket text message. It passes each reply from the app back to the script as one line. The smoke tests start it in `start_test_app`, on ports the system chooses.

A command is one line holding a JSON object with a `command` field, and the reply is one line. Commands are handled one at a time, and held until the frontend reports it is listening (`window.ziggy.testUiReady()`).

Commands Ziggy handles itself:

| Command | What it does |
|---|---|
| `{"command": "quit"}` | Quits the app through the native app. When the app has not stopped 10 seconds later, as on MacOS while the system's file panel service keeps the main thread waiting, the process is ended with exit status 1. |
| `{"command": "menu", "action": "..."}` | Chooses a menu item as a user would. The native app's own actions really happen, and any other action reaches the frontend. An `.action` item's action reaches its frontend handler. After `reload`, commands wait until the frontend is listening again. |
| `{"command": "pick-answer", "paths": [...]}` | Gives the next file or directory dialog these paths, and no dialog is shown. |
| `{"command": "drop", "paths": [...]}` | Records a drop of these files, as the native app does when the user drops them. |
| `{"command": "screenshot", "outputPath": "<absolute path>"}` | Writes a PNG of the app's window to the path once the frontend is ready. On Android and the iOS simulator the smoke test scripts take it from the host instead, of the whole screen. The Windows and macOS native apps have not been built or run on those systems yet. |

Every other command goes to the frontend as a `test-command` event, which the frontend hears through `window.ziggy.onTestCommand`, and the frontend replies with `window.ziggy.sendTestResult(requestId, result)`. The template's frontend handles `ready`, `click`, `type`, `get-value`, `get-text`, `exists`, `viewport`, `insert` and `drop-file`, finding elements by `data-id`.

`32-external-links` checks that a link to an outside page reaches the system on every platform. On Linux it first runs with every URL handler hidden (`XDG_DATA_DIRS` narrowed and no session bus) and checks that the failed open reaches the app's log, then starts the app with a URL handler of the scenario's own, found through `XDG_CONFIG_HOME` and `XDG_DATA_HOME`, which records each address the system is asked to open. On Android it reads the activity starts from the device log. Two of its links open 6 s after the click, so no user gesture is behind them. On Windows, macOS and iOS, where no hook reports the open, it checks that the app is still running five seconds after each open and, on Windows and macOS, that the frontend still holds its marker.

### Several windows

Each app started with the same `--remote-control` address is a window of its own, numbered from 1 in the order it connects. A closed window's number goes to the next app that connects once the server has seen the closed window's connection end.

A command goes to window `<n>` with `"window": <n>` added to its JSON object, and to window 1 without it. A command for a window that has not connected yet waits for it, so a test sends the command straight after starting the app. A `window` that is not a whole number from 1 to the server's window limit (`WINDOW_COUNT_MAX` in `tools/remote-control-server/src/lib/remote-control-server.ts`) gets `InvalidWindow`.

A scenario that restarts the app starts a new remote control server for it, so the restarted app is window 1. The test app's `restart_test_app` does this.

The Linux smoke library starts Xvfb on its own, in a process group apart from the app's, so the display outlives window 1 and every other window keeps its display. On Windows the smoke library ends each window by the process id the app's log records, in the `Started a new window, process <pid>.` line and in the window's own log file name.

## See also

- [Scripts](scripts.md): the scripts that run the tests.
- [Ziggy architecture](../development/architecture.md#remote-control): where the remote control connection fits in an app.
