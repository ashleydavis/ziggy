# Ziggy template

The template a new app on Ziggy is copied from. It has a UI (TypeScript and HTML, which runs in the system web view), a Zig backend with its own message handlers and task handlers, a native app for each platform, and its tests. It takes Ziggy as a dependency exactly as an app in another repository does, and nothing in Ziggy knows about it. Terms are defined in [Ziggy's glossary](https://github.com/ashleydavis/ziggy/blob/main/docs/glossary.md).

## Hello world

The template is the smallest complete app: a hello world for each kind of code an app has, each with its test. Change each one into your own code and tests, or delete it.

| Kind | Code | Test |
|---|---|---|
| UI | `ui/src/lib/hello-world-ui.ts`, used by `ui/src/main.ts` | `ui/src/test/hello-world-ui.test.ts` (`bun run test`) |
| Backend: a message handler and a task | `backend/src/lib/hello-world-backend.zig`, registered in `backend/src/app.zig` | `backend/src/test/hello-world-backend.test.zig` (`bun run test:zig`) |
| The whole app | The app | `smoke-tests/hello-world-app/test.sh` (`bun run test:smoke`) |

The page shows the backend's message response to the `hello-world` message, and a button starts the `hello-world-task` task and shows what it sends. The desktop menu is defined once in Zig (`backend/src/lib/menu.zig`) and drawn natively; a mobile device shows no menu.

## Where things are

Everything here is the template's own. Ziggy, the package it is built on, is in `packages/ziggy` of Ziggy's repository.

- `build.zig` and `build.zig.zon`: the template's Zig build. It takes Ziggy as the dependency `ziggy` by the path `../..`, and builds the backend (`ziggy-template-backend`), the Linux and Windows native apps (`ziggy-template-linux`, `ziggy-template-windows`) and the backend's unit tests (`test`) with Ziggy's build functions.
- `ui/`: the UI. `ui/index.html` is the UI and `ui/src/lib` holds the plain functions that have unit tests. `vite.config.ts` is its build, which writes `dist` with relative paths and a classic script so it loads from an address of the app's own in every web view. `dist` is embedded in the app's own code on every platform (the Linux and Windows executables, and the backend library that the MacOS, iOS and Android apps contain), so no platform has a directory of UI files.
- `backend/`: the template's Zig library, which adds its message handlers and task handlers to Ziggy's core library.
- `native/<platform>/`: the template's native project for each platform: its name, window, icon and the app's backend and UI packaged together. Each one builds on the part Ziggy provides for that platform, in `packages/ziggy/native/<platform>` of Ziggy's repository: the Linux and Windows native apps through the Zig build, the Xcode projects through a local Swift package and the Android project through an included Gradle build.
- `scripts`: the build, run, packaging and setup scripts, and the shell libraries the scripts share (`scripts/lib`), each with a markdown file beside it.
- `smoke-tests`: the smoke tests, with a library for each platform that builds, starts and stops the app. See `smoke-tests/run.md`.

## Commands

The scripts are in Ziggy's [Scripts](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/scripts.md).

## What each platform needs

What each platform needs installed, what each dependency is and why it is needed, is in Ziggy's [Dependencies](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/dependencies.md). Run `bun run setup` once on each machine to install what it can.

## Test hooks

The smoke tests drive the real app through the test hooks listed in "Test hooks" in the architecture guide: `backend/src/lib/ui-query.zig` tells the UI it is in test mode, and `ui/src/lib/test-commands.ts` handles the commands the smoke tests send. They are compiled in only by the `test-hooks` build option, which the smoke test runner sets and the `package` commands never do.

## CI

The repository's release workflow (`.github/workflows/release.yml`) builds and packages the template and runs its unit tests on Linux, Windows, MacOS, iOS and Android on every push, and publishes the packages when every job passed on the default branch.

## See also

- [Ziggy's repository](https://github.com/ashleydavis/ziggy): the package the template is built on.
- [Ziggy architecture](https://github.com/ashleydavis/ziggy/blob/main/docs/development/architecture.md): how the parts fit, including [the bundled UI](https://github.com/ashleydavis/ziggy/blob/main/docs/development/architecture.md#the-bundled-ui) and the test hooks.
- [Building your app](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/building-your-app.md): starting a new app from the template.
- [Releasing Ziggy](https://github.com/ashleydavis/ziggy/blob/main/docs/development/releasing-ziggy.md): the release workflow.
