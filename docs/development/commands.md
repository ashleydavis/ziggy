# Commands in Ziggy's repository

Terms are defined in the [glossary](../glossary.md). An app's own scripts are in [Scripts](../user-guide/scripts.md).

`<platform>` is `linux`, `windows`, `macos`, `android` or `ios`, and each platform's commands run on that platform: Linux on Linux, Windows under Git Bash on Windows, macOS and iOS on a Mac with Xcode 14.2 or newer, Android on Linux or a Mac.

Run from the root of Ziggy's repository.

| Command | What it does |
|---|---|
| `bun run setup` | Runs the `setup` of the template and of the test app. |
| `bun run compile` (alias `bun run c`) | Type-checks the TypeScript: `ziggy`, the template's UI and the test app's UI. |
| `bun run compile:zig` | Runs the `compile:zig` of the template and of the test app. |
| `bun run test` (alias `bun run t`) | The TypeScript unit tests: `ziggy`, the template's UI and the test app's UI. |
| `bun run test:zig` | Every Zig test (`zig build test`): Ziggy's core library and its task queue, the parts of the Linux and Windows native apps that need no platform, the dev backend, the template's backend and the test app's backend. It builds each app's UI first. `bun run test:zig -- -Dtest-filter=<text>` runs only the tests of Ziggy's core library whose names contain the text. The option may be given more than once. Every other suite still runs in full. |
| `bun run test:zig:android` | The Zig unit tests of Ziggy's core library and the test app's backend, on an Android emulator or device. |
| `bun run test:zig:ios` | The Zig unit tests of Ziggy's core library and the test app's backend, on a booted iOS simulator. |
| `bun run test:android-shell` | The JUnit tests of Ziggy's Android native app, on this machine's JVM. Needs no device. |
| `bun run diagrams` | Draws every diagram under `docs/development/diagrams` from its Mermaid source into the SVG the docs show. |
| `bun run <command>:ziggy-template:<platform>` | Runs the template's `<command>:<platform>`, for `sync`, `build`, `run`, `open`, `package` and `clean`. |
| `bun run distribute:ziggy-template:android` | Runs the template's `distribute:android`. |
| `bun run dev:ziggy-template` | Runs the template's `dev`. |
| `bun run test:smoke` | Ziggy's smoke tests, which drive its test app (`apps/ziggy-test-app`), on this machine's desktop platform. `test:smoke:and`, `test:smoke:ios` and `test:smoke:dev` run them on an attached Android emulator or device (the ones `ZIGGY_ANDROID_DEVICES` names, when it is set), on a connected iPhone or iPad or else the iOS simulator, and in dev mode in a headless Chrome or Chromium. `-- <number\|name>` after any of them runs one scenario. |

Any other command of the template runs from the root with `bun run --filter=ziggy-template <command>`.

## Dev mode

An app's `bun run dev` runs the supervisor (`zig build <name>-dev`). Its options go after `--`, as in `zig build my-app-dev -- --no-open`:

| Option | What it does |
|---|---|
| `--no-open` | Leaves the browser closed. The address to open is printed. |
| `--port <port>` | Serves the app on that port instead of one the operating system chooses. |
| `--test-hooks` | Builds the dev backend with the test hooks, so a test can drive it as it drives a native app's test build. |

`zig build <name>-dev-host` builds the dev backend alone, to `zig-out/bin/<name>-dev-host`. It takes `--data-dir <dir>` (the app's data directory) and `--ui-port <port>` (the port of the dev server it forwards to), and optionally `--port <port>` and `--port-file <file>` (where it writes the port it listens on). In a build with the test hooks it starts in test mode when `ZIGGY_TEST_MODE` is set, as a native app does.

## See also

- [Dependencies](../user-guide/dependencies.md): what to install on each platform before these commands run, what each dependency is and why it is needed.
- [Developing Ziggy](developing-ziggy.md#setting-up): setting up Ziggy's repository.
- [Smoke tests](../../smoke-tests/run.md): how the smoke tests run.
