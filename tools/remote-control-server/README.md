# ziggy-remote-control-server

The remote control server lets a smoke test script drive a Ziggy app. The app's remote control code is in every build and does nothing unless the app is started with `--remote-control <host:port>` (the `ziggy.remoteControl` extra on Android). An app started that way connects out to the server, and the test script connects to the server too. The server passes each line the script writes to the app and each reply the app sends back to the script.

## Usage

`ziggy-remote-control-server --app-port <port> --script-port <port>`

Run it from a project that depends on Ziggy with `bun run ziggy-remote-control-server ...`. The smoke tests start it in `start_test_app` (`smoke-tests/lib/common.sh`).

## Arguments

- `--app-port <port>`: the loopback port the app connects to. It is an Express server, and the app opens a WebSocket connection to `ws://127.0.0.1:<port>/`. A mobile reaches it through `adb reverse` on Android, and the iOS simulator shares the Mac's loopback address.
- `--script-port <port>`: the loopback port the test script connects to, a plain TCP server that bash reaches with `/dev/tcp/127.0.0.1/<port>`.

Both are required, from 0 to 65535, and different unless both are 0. A port of 0 lets the system choose a free one. Once both ports listen, the server writes `The remote control server is listening: the app on 127.0.0.1:<app port>, the script on 127.0.0.1:<script port>.` to stderr, and the smoke tests start it with ports of 0 and read the ports from that line, so two runs never ask for the same port.

## What it does

- It listens on `127.0.0.1` only. A port already in use ends it at once with an error naming the port.
- Each line from the script goes to the app as one WebSocket text message, and each text message from the app goes back to the script as one line, in order.
- Many apps can be connected at once, each numbered with the lowest number from 1 that no connected app has, and one script is connected at a time, a new script connection replacing the one before it.
- A line goes to the window its `"window": <n>` field names, or window 1 when it has none, with the field taken off. A line that is not a JSON object, or has no `window` field, goes to window 1 unchanged.
- A line with a `window` field reaches the app as its JSON value written again compactly by `JSON.stringify`, with its other keys in their order: numbers and string escapes are written as `JSON.stringify` writes them, an integer beyond 2^53 is rounded, a key given twice keeps its last value, a number outside the double range (`1e999`) is written as `null`, and a key whose name is an integer-like string comes before the other keys.
- A `window` that is not a whole number from 1 to the server's window limit (`WINDOW_COUNT_MAX` in `src/lib/remote-control-server.ts`) gets `{"ok":false,"error":"InvalidWindow"}`. When the server sees an app's connection end, its number is free for the next app.
- A scenario that restarts the app starts a new server for the new run, and a new server holds no app, so the new app is window 1. A line the app was sent and did not answer before it went gets `{"ok":false,"error":"AppDisconnected"}`.
- A line for a window that is not connected waits for that window for the server's app wait (`APP_WAIT_TIMEOUT_MS` in `src/index.ts`), then gets `{"ok":false,"error":"AppNotConnected"}`.
- A reply whose script has gone is dropped and reported.
- Every failure is written to stderr with what failed and the port involved. A failure to start exits with code 1, and a wrong command line with code 2.
- It ends with code 0 when its stdin closes or it receives SIGTERM. The test starts it with a stdin it holds open, so the server ends with the test even when the test is killed.

## Development

- `bun run compile` type-checks it.
- `bun run test` runs its unit tests, which start real servers on free loopback ports.
