# Ziggy dev host

Dev mode runs an app's UI in an ordinary browser instead of the system web view, with live reload. It is for developing an app only: no native app and no release build includes any of it. It is three programs:

- **The app's own dev server**, from whichever bundler the app uses, serves the UI with its own live reload. It needs nothing of Ziggy's.
- **The dev host** runs the app's core, which a browser cannot run because it is compiled Zig. It plays the part a native app plays, through the same C interface (`ziggy.h`): it creates the core, carries the page's messages to it over a WebSocket and answers the core's native host callbacks. It also stands in front of the dev server: the browser opens the dev host, which answers `/__ziggy` itself and forwards everything else to the dev server, putting Ziggy's two scripts at the start of each page on the way through. It listens on `127.0.0.1` only.
- **The supervisor** starts the dev server, builds the dev host, starts it and opens the browser, once both are ready. It watches the Zig files of the app and of Ziggy: a saved Zig file rebuilds the dev host and restarts it on the same port, and the page reloads once the new one answers. A build that fails is reported, and the dev host that was running keeps running until the next save.

The UI and its `window.ziggy` are the same as in the native app, so the same UI code runs in both.

## Setting it up

`addAppCore` adds the `<name>-dev-host` and `<name>-dev` build steps to every app. The app's `package.json` has two scripts:

```json
"dev": "zig build my-app-dev",
"dev:ui": "vite"
```

`dev:ui` runs the bundler's dev server, whatever the bundler: `vite` in the Ziggy template and `rsbuild dev` in the Rsbuild example (`ziggy-example-rsbuild`, beside the ziggy repository). The supervisor runs it with `--port <port> --host 127.0.0.1`, which both take. Nothing else changes: the bundler's config is the app's own, with nothing of Ziggy's in it.

`bun run dev` starts it all. The supervisor says what it is doing while it builds, and opens the browser at the dev host's address once the dev server and the dev host are both up. Ctrl+C stops all three. Options go after `--`, as in `zig build my-app-dev -- --no-open`:

| Option | What it does |
|---|---|
| `--no-open` | Leaves the browser closed. The address to open is printed. |
| `--port <port>` | Serves the app on that port instead of one the operating system chooses. |
| `--test-hooks` | Builds the dev host with the test hooks, so a test can drive it as it drives a native app's test build. |

## What differs from a native app

- **File and folder dialogs.** On Linux the dev host shows them itself with zenity, which must be installed, and the UI gets the real paths chosen. On Windows and macOS they are missing, as below.
- **What only a native app can do** has no native host callback here: menus, screenshots and the app's own host requests. The core answers each with `HostCallbackMissing`, so the UI sees an error, never a pretend result.
- **Dropped files.** A browser gives a page no dropped file's path. The inject script hands a drop's files over as it does in WebView2, through `window.chrome.webview.postMessageWithAdditionalObjects`, which the dev script provides. The dev script sends each file to the dev host, which saves a copy under `<data dir>/dropped`, and records the copies' paths with the core as the drop, holding back the page's messages to the core until it has, so the inject script's request for the drop's paths gets the copies'. `window.ziggy.getPathForFile` then gives the path of the copy, which the core can read.
- **Keeping the app running.** The dev host runs until it is stopped, whether or not the page is open, so a task that keeps the app running in the background goes on when the page is closed.
- **Rendering.** The page renders in the browser's engine, not the platform's web view. Check what the UI looks like in the native app on each platform as well.
- **The UI's query.** A native app loads the UI with the query the core makes (the test mode switch, in a test build). `/__ziggy/start` sends the browser to the UI with that query. The plain address has none, which is all a normal run makes anyway.

## How it works

- The dev host's core embeds no UI, because the dev server serves the UI, so dev mode needs no UI build.
- The dev host answers `/__ziggy/dev.js` (the dev script), `/__ziggy/inject.js` (the inject script), `/__ziggy/alive`, `/__ziggy/start`, the dropped file uploads and the WebSocket at `/__ziggy/socket`.
- Everything else goes to the dev server. Each request is sent on a connection of its own that closes after the answer, asking for the answer uncompressed, so a page can have the scripts put in it. Any other answer is passed back as it came. A WebSocket the dev server serves, such as its live reload, is passed through byte for byte in both directions.
- Messages the core sends while no page is connected wait for the next page.
- When the WebSocket to the core closes, the page asks `/__ziggy/alive` until the dev host answers and then reloads.
- The supervisor sees a change by adding up the path, size and modification time of every Zig file every quarter of a second, which works the same on every operating system. Build outputs, caches, `node_modules` and hidden directories are left out.
- The dev server and the dev host are in the terminal's process group with the supervisor, so Ctrl+C stops them all. The supervisor stops both itself when it ends for any other reason.

## Running the parts alone

`zig build <name>-dev-host` builds the dev host alone, to `zig-out/bin/<name>-dev-host`. It takes `--data-dir <dir>` (the app's data directory) and `--ui-port <port>` (the port of the dev server it forwards to), and optionally `--port <port>` and `--port-file <file>` (where it writes the port it listens on). In a build with the test hooks it starts in test mode when `ZIGGY_TEST_MODE` is set, as a native app does.

## Code

- `src/lib/dev-host.zig`: the dev host.
- `src/lib/proxy.zig`: what the dev host makes of the requests it forwards and the answers that come back.
- `src/lib/supervisor.zig`: the supervisor.
- `src/lib/dev-client.js`: the dev script. Its unit tests are in `packages/ziggy/ui/src/test/dev-client.test.ts`.
- `src/lib/web-socket.zig`: reads the page's WebSocket messages, joining the frames a browser splits a large message into.
- `src/lib/pickers.zig`: the file and folder dialogs, shown with zenity on Linux, with unit tests under `src/test`.
- `src/lib/request-paths.zig`, `src/lib/args.zig` and `src/lib/watch.zig`: what the two make of dropped file names, command lines and files, with unit tests under `src/test`.
- `src/dev-host-main.zig` and `src/supervisor-main.zig`: the two programs' entry points.

The Ziggy template's smoke tests run every scenario that does not need a native app in dev mode, against the dev host in front of Vite with the UI in a headless Chrome or Chromium (`bun run test:ziggy-template:dev` from the root of the repository). The `dev-only` scenarios check what only dev mode does: `22-hot-reload` runs the whole of it as a developer does, through the supervisor, and checks that a UI change and a Zig change both reach the page, and `23-drop-files` checks a dropped file.
