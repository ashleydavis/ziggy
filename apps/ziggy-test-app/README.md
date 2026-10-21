# Ziggy test app

The app Ziggy's own tests drive: it has a feature for each part of Ziggy, and nobody copies it. Ziggy's smoke tests (`smoke-tests` at the root of the repository) drive it on every platform, and its unit tests check its features. A new app starts from the Ziggy template instead. It has a UI (TypeScript and HTML, which runs in the system web view), a Zig backend with its own channel handlers and task handlers, a native app for each platform and unit tests of its UI and backend. It takes Ziggy as a dependency exactly as an app in another repository does, and nothing in Ziggy knows about it. Terms are defined in [Ziggy's glossary](https://github.com/ashleydavis/ziggy/blob/main/docs/glossary.md).

## What it shows

- The UI sends a message on the `ping` channel and shows the backend's message response.
- Tasks: a short task, a long task that queues child tasks and waits for them, several long tasks at once, cancelling by source and a task that fails. Output text, `job-progress` messages and every `task-message` and `task-completed` event appear in the UI.
- The edges of the bridge: a multi-megabyte payload, text with quotes, newlines and non-ASCII characters, an error message response and a file written and read in the app's private data directory.
- A native call: the UI sends a message for the operating system's version, a task calls the native app's callback and the result comes back to the UI.
- File and directory pickers: three buttons send the backend messages that show the native dialogs (`pick-files`, `pick-folder`, `pick-file`), and the UI shows the paths chosen. A mobile device has no save dialog, so that button gives an error on iOS.
- A loopback HTTP server in the backend (the test app's own code, not Ziggy's) that serves an example image and video to the UI, which loads them and fetches a range of bytes with a `Range` header.
- Keep-alive tasks: a background task type registered as keep-alive that goes on running when the app is sent to the background (a mobile device), and a normal one that does not.
- UI storage: `localStorage` and IndexedDB values the UI writes and reads back after the app is started again.
- The UI's address: the address and origin the UI is served from, whether it is a secure context and whether `localStorage`, IndexedDB, and `fetch` and `XMLHttpRequest` of the UI's own files work there.
- Dropped files: a drop zone that shows the real path of a dropped file, from `window.ziggy.getPathForFile`.
- A desktop menu defined once in Zig and drawn natively, with keyboard shortcuts that work anywhere in the window, and developer tools (Ctrl+Shift+I, or Cmd+Shift+I on a Mac) that open from it. A mobile device shows no menu.

## Where things are

Everything here is the test app's own. Ziggy, the package it is built on, is in `packages/ziggy` of Ziggy's repository.

- `build.zig` and `build.zig.zon`: the test app's Zig build. It takes Ziggy as the dependency `ziggy` by the path `../..`, and builds the backend (`ziggy-test-app-backend`), the Linux and Windows native apps (`ziggy-test-app-linux`, `ziggy-test-app-windows`) and the backend's unit tests (`test`) with Ziggy's build functions.
- `ui/`: the UI. `ui/index.html` is the UI and `ui/src/lib` holds the plain functions that have unit tests. `vite.config.ts` is its build, which writes `dist` with relative paths and a classic script so it loads from an address of the app's own in every web view. `dist` is embedded in the app's own code on every platform (the Linux and Windows executables, and the backend library that the MacOS, iOS and Android apps contain), so no platform has a directory of UI files.
- `backend/`: the test app's Zig library, which adds its channel handlers and task handlers to Ziggy's core library.
- `native/<platform>/`: the test app's native project for each platform: its name, window, icon and the app's backend and UI packaged together. Each one builds on the part Ziggy provides for that platform, in `packages/ziggy/native/<platform>` of Ziggy's repository: the Linux and Windows native apps through the Zig build, the Xcode projects through a local Swift package and the Android project through an included Gradle build.
- `scripts`: the build, run, packaging and setup scripts, and the shell libraries the scripts share (`scripts/lib`), each with a markdown file beside it.

## Commands

The scripts are in Ziggy's [Scripts](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/scripts.md).

## What each platform needs

What each platform needs installed, what each dependency is and why it is needed, is in Ziggy's [Dependencies](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/dependencies.md). Run `bun run setup` once on each machine to install what it can.

## Test hooks

The UI and the backend carry the test hooks that Ziggy's own smoke tests (in `smoke-tests` at the root of Ziggy's repository) drive the test app with, listed in "Test hooks" in the architecture guide. They are compiled in only by the `test-hooks` build option, which the `package` commands never set.

## CI

The repository's release workflow (`.github/workflows/release.yml`) runs Ziggy's smoke tests and the test app's unit tests on Linux, Windows, MacOS, iOS and Android on every push.

## See also

- [Ziggy's repository](https://github.com/ashleydavis/ziggy): the package the test app is built on.
- [Ziggy architecture](https://github.com/ashleydavis/ziggy/blob/main/docs/development/architecture.md): how the parts fit, including [the bundled UI](https://github.com/ashleydavis/ziggy/blob/main/docs/development/architecture.md#the-bundled-ui) and the test hooks.
- [Building your app](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/building-your-app.md): starting a new app from the test app.
- [Releasing Ziggy](https://github.com/ashleydavis/ziggy/blob/main/docs/development/releasing-ziggy.md): the release workflow.
