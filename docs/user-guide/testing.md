# Testing your app

Terms are defined in the [glossary](../glossary.md).

An app has unit tests for its frontend (`frontend/src/test`) and its backend (`backend/src/test`), and smoke tests (`smoke-tests`) that start the real app and drive it from outside. The scripts that run them are in [Scripts](scripts.md).

## Test hooks

A smoke test cannot click a native file dialog, read what the web view shows or wait for the frontend to finish loading, so the app offers a way in: the test hooks.

- The remote control code is in every build. It does nothing unless the app is started with `--remote-control <host:port>`. On Android the address is the string Intent extra `ziggy.remoteControl`.
- Test mode is on exactly when the app is started that way. The template's backend tells the frontend through the `testMode=1` query parameter.
- A test sets up its state from outside the app, with config files and data placed on disk, wherever it can.
- Add a hook of the app's own only where nothing outside the app can do the job.

The native apps take `--remote-control` and its address out of the command line, so the app's own argument handling never sees them.

## The remote control connection

The app connects out to the remote control server at the address it was given. It opens one WebSocket connection to `ws://<host:port>/`, on a thread of its own. When the connection cannot be made, the app prints the address and fails to start.

The [remote control server](../../tools/remote-control-server/README.md) is a separate program, `ziggy-remote-control-server`, which an app gets from the Ziggy repository as a dev dependency. It listens on one port for the app and on another for the test script. It passes each line the script writes to the app as one WebSocket text message. It passes each reply from the app back to the script as one line. The smoke tests start it in `start_test_app`, on ports the system chooses.

A command is one line holding a JSON object with a `command` field, and the reply is one line. Commands are handled one at a time, and held until the frontend reports it is listening (`window.ziggy.testUiReady()`).

Commands Ziggy handles itself:

| Command | What it does |
|---|---|
| `{"command": "quit"}` | Quits the app through the native app. When the app has not stopped 10 seconds later, as on MacOS while the system's file panel service keeps the main thread waiting, the process is ended with exit status 1. |
| `{"command": "menu", "action": "..."}` | Chooses a menu item as a user would. The native app's own actions really happen, and any other action reaches the frontend. After `reload`, commands wait until the frontend is listening again. |
| `{"command": "pick-answer", "paths": [...]}` | Gives the next file or directory dialog these paths, and no dialog is shown. |
| `{"command": "drop", "paths": [...]}` | Records a drop of these files, as the native app does when the user drops them. The native app's own reading of a real drop is not covered. |
| `{"command": "screenshot", "outputPath": "<absolute path>"}` | Writes a PNG of the app's window to the path once the frontend is ready. On Android and the iOS simulator the smoke test scripts take it from the host instead, of the whole screen. The Windows and macOS native apps have not been built or run on those systems yet. |

Every other command goes to the frontend as a `test-command` event, which the frontend hears through `window.ziggy.onTestCommand`, and the frontend replies with `window.ziggy.sendTestResult(requestId, result)`. The template's frontend handles `ready`, `click`, `type`, `get-value`, `get-text`, `exists`, `viewport`, `insert` and `drop-file`, finding elements by `data-id`.

## See also

- [Scripts](scripts.md): the scripts that run the tests.
- [Ziggy architecture](../development/architecture.md#remote-control): where the remote control connection fits in an app.
