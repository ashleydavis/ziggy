# Dev mode

How dev mode works inside: the dev backend and the supervisor. Terms are defined in the [glossary](../glossary.md).

For how to use it, see [Dev mode](../user-guide/dev-mode.md) in the user guide.

Dev mode runs an app while it is developed, with the frontend in an ordinary browser instead of the system web view. It is three programs:

- **The app's own dev server**, from whichever bundler the app uses (its `dev:ui` script), serves the frontend with its own live reload. Nothing of Ziggy's is in it or in the bundler's config.
- **The dev backend** takes the native app's place. It is a program linked with the app's backend, built with no frontend in it, that calls the same C interface a native app calls: it creates the core library and carries the page's messages to it over a WebSocket. It stands in front of the dev server: the browser opens the dev backend, which serves `/__ziggy` itself and forwards everything else to the dev server, putting its dev script and the inject script at the start of each page. The dev script gives the inject script the message handler it looks for, so the inject script and the core library hold nothing of dev mode and the frontend's `window.ziggy` is the same as in a native app.
- **The supervisor** (`<name>-dev`) starts the dev server, builds and starts the dev backend, opens the browser, and rebuilds and restarts the dev backend when a Zig file of the app or of Ziggy changes.

`addAppBackend` adds the dev backend's build steps, `<name>-dev-host` and `<name>-dev`. Nothing else links the dev backend, so no native app and no release build includes any of it.

How the dev backend differs from a native app beyond its native calls:

- **Dropped files.** The inject script hands a drop's files over as it does in WebView2, through `window.chrome.webview.postMessageWithAdditionalObjects`, which the dev script provides. The dev script sends each file to the dev backend, which saves a copy under `<data dir>/dropped` and records the copies' paths with the backend as the drop, holding back the page's messages to the backend until it has, so the inject script's `get-dropped-paths` message gets the copies'. `window.ziggy.getPathForFile` then gives the path of the copy, which the backend can read.
- **Keeping the app running.** The dev backend runs until it is stopped, whether or not the page is open, so a task that keeps the app running in the background goes on when the page is closed.
- **The frontend's query.** A native app loads the frontend with the query the backend makes (the test mode switch, in a test build). `/__ziggy/start` sends the browser to the frontend with that query, and it is the address the supervisor prints and opens. The plain address has none.

How it works:

- The dev backend listens on `127.0.0.1` only. Its backend embeds no frontend, because the dev server serves the frontend, so dev mode needs no frontend build.
- The dev backend serves `/__ziggy/dev.js` (the dev script), `/__ziggy/inject.js` (the inject script), `/__ziggy/alive`, `/__ziggy/start`, the dropped file uploads and the WebSocket at `/__ziggy/socket`.
- Everything else goes to the dev server. Each request is sent on a connection of its own that closes after the response, with `accept-encoding: identity` so the response comes back uncompressed, so a page can have the scripts put in it. Any other response is passed back as it came. A WebSocket the dev server serves, such as its live reload, is passed through byte for byte in both directions.
- Messages the backend sends while no page is connected wait for the next page.
- When the WebSocket to the backend closes, the page fetches `/__ziggy/alive` until the dev backend responds and then reloads. The supervisor restarts the dev backend on the same port, so the page finds it again.
- The supervisor sees a change by adding up the path, size and modification time of every Zig file every quarter of a second, which works the same on every operating system. Build outputs, caches, `node_modules` and hidden directories are left out.
- The dev server and the dev backend are in the terminal's process group with the supervisor, so Ctrl+C stops them all. The supervisor stops both itself when it ends for any other reason.

The code is in `packages/ziggy/dev`: the dev backend (`src/lib/dev-host.zig`), what it makes of the requests it forwards and the responses that come back (`src/lib/proxy.zig`), the supervisor (`src/lib/supervisor.zig`), the dev script (`src/lib/dev-client.js`, with its unit tests in `packages/ziggy/frontend/src/test/dev-client.test.ts`), the page's WebSocket messages (`src/lib/web-socket.zig`), the zenity dialogs (`src/lib/pickers.zig`), what the two programs make of dropped file names, command lines and files (`src/lib/request-paths.zig`, `src/lib/args.zig` and `src/lib/watch.zig`) and the two programs' entry points (`src/dev-host-main.zig` and `src/supervisor-main.zig`). The commands that start dev mode and the dev backend's options are in [Commands in Ziggy's repository](commands.md#dev-mode).
