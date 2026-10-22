# Testing your app

Terms are defined in the [glossary](../glossary.md).

An app has unit tests for its frontend (`frontend/src/test`) and its backend (`backend/src/test`), and smoke tests (`smoke-tests`) that start the real app and drive it from outside. The scripts that run them are in [Scripts](scripts.md).

## Test hooks

A smoke test cannot click a native file dialog, read what the web view shows or wait for the frontend to finish loading, so the app offers a way in: the test hooks.

- They are compiled in only with the `test-hooks` build option (`-Dtest-hooks=true`), which is off by default. Release builds never use it, so a released app has no test mode and no control connection.
- A test sets up its state from outside the app, with config files and data placed on disk, wherever it can.
- Add a hook of the app's own only where nothing outside the app can do the job.

The native app reads two environment variables, in a test build only. On Android they arrive as Intent extras, and on the iOS simulator as `SIMCTL_CHILD_`-prefixed variables.

- `ZIGGY_TEST_MODE` switches the hooks on. The frontend is told through the `testMode=1` query parameter.
- `ZIGGY_TEST_PORT_FILE` names the file the backend writes the control connection's port to.

## The control connection

The control connection listens on the loopback address, on a port the operating system chooses. A command is one line holding a JSON object with a `command` field, and the reply is one line. Commands are handled one at a time, and held until the frontend reports it is listening (`window.ziggy.testUiReady()`).

Commands Ziggy handles itself:

| Command | What it does |
|---|---|
| `{"command": "quit"}` | Quits the app through the native app. |
| `{"command": "menu", "action": "..."}` | Chooses a menu item as a user would. The native app's own actions really happen, and any other action reaches the frontend. After `reload`, commands wait until the frontend is listening again. |
| `{"command": "pick-answer", "paths": [...]}` | Gives the next file or directory dialog these paths, and no dialog is shown. |
| `{"command": "drop", "paths": [...]}` | Records a drop of these files, as the native app does when the user drops them. The native app's own reading of a real drop is not covered. |
| `{"command": "screenshot", "outputPath": "<absolute path>"}` | Writes a PNG of the app's window to the path once the frontend is ready. On Android and the iOS simulator the smoke test scripts take it from the host instead, of the whole screen. The Windows and macOS native apps have not been built or run on those systems yet. |

Every other command goes to the frontend as a `test-command` event, which the frontend hears through `window.ziggy.onTestCommand`, and the frontend replies with `window.ziggy.sendTestResult(requestId, result)`. The template's frontend handles `ready`, `click`, `type`, `get-value`, `get-text`, `exists`, `viewport`, `insert` and `drop-file`, finding elements by `data-id`.

## See also

- [Scripts](scripts.md): the scripts that run the tests.
- [Ziggy architecture](../development/architecture.md#test-hooks): where the test hooks fit in an app.
