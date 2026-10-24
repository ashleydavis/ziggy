# Dev mode

Dev mode runs your app's frontend in an ordinary browser while you develop it, with the backend behind it, and reloads as you save.

Terms are defined in the [glossary](../glossary.md).

## Starting dev mode

Run `bun run dev`. It starts your app's own dev server, builds the dev backend and opens the frontend in the default browser once both are up, reporting what it is doing while it builds. If that first build fails, `bun run dev` stops.

## Saving files

- Saving a file under `frontend/` reaches the page through the dev server's own live reload. Nothing of Ziggy's is rebuilt.
- Saving a Zig file of the app or of Ziggy rebuilds the dev backend and restarts it, and the page reloads once it is back. The backend starts again, so tasks that were running are gone.
- A Zig build that fails is reported in the terminal, and the dev backend that was running keeps running until the next save.

## What works in the browser

The frontend is the same code as in the native app and talks to the backend through the same `window.ziggy`.

- What only the native app can do (menus, screenshots and the app's own native calls) fails with the error `NativeCallMissing`.
- File and directory dialogs work on Linux, where the dev backend shows them with zenity, and fail with `NativeCallMissing` on Windows and macOS.
- A dropped file's path is the path of a copy the dev backend saves, because a browser gives a page no file's path.
- The page renders in the browser's engine, so check the native app on each platform as well.

## The scripts it needs

Dev mode needs these scripts in the app's `package.json`, which the template has:

```json
"dev": "zig build my-app-dev",
"dev:ui": "vite"
```

`dev:ui` runs the bundler's dev server (`rsbuild dev` for Rsbuild), and dev mode gives it `--port <port> --host 127.0.0.1`.

For how dev mode works inside, see [Dev mode](../development/dev-mode.md) in the development docs.
