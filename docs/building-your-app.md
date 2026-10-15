# Building your app

A new app starts as a copy of the Ziggy template (`apps/ziggy-template`), which is a complete app with a UI, a Zig backend, a native project for each platform, tests and scripts to build, run and package it. The copy is the app's own code from then on. Ziggy itself is never copied: the app takes it as a dependency. Terms are defined in the [glossary](glossary.md).

## Starting a new app from the template

The quickest way is the `/ziggy:new` Claude Code command, which does these steps for you, asks for the app's names as it goes and pins the app to Ziggy's latest release. [Claude Code commands](claude-code-commands.md) says how to get it.

Without the command:

1. Find Ziggy's latest release, the highest version tag of its repository. The tag is the last part of the line this prints (`refs/tags/<tag>`):

   ```bash
   git ls-remote --tags --refs --sort=-version:refname https://github.com/ashleydavis/ziggy 'v*' | head -n 1
   ```

2. In the new app's empty folder, download the template and Ziggy's `mise.toml` of that release, and install the tools. The archive holds only the files in the repository, so nothing a build writes comes with it:

   ```bash
   curl -fsSL https://github.com/ashleydavis/ziggy/archive/refs/tags/<tag>.tar.gz | tar -xz --strip-components=3 --wildcards '*/apps/ziggy-template/*'
   curl -fsSL -o mise.toml https://raw.githubusercontent.com/ashleydavis/ziggy/<tag>/mise.toml
   mise trust
   mise install
   ```

3. Pin every part to that release, with the lines [Integrating Ziggy](integrating-ziggy.md) gives for a version tag, all naming the same tag:
   - `build.zig.zon`: the `ziggy` dependency. Delete the `.fingerprint` line; `zig build` then prints a new one, which goes back in.
   - `package.json`: `ziggy-ui`, in place of `workspace:*`.
   - `shells/android/settings.gradle` and `shells/android/app/build.gradle`: Ziggy's Android native app.
   - `shells/macos/ZiggyTemplate.xcodeproj/project.pbxproj` and `shells/ios/ZiggyTemplate.xcodeproj/project.pbxproj`: the `macos` or `ios` Swift package.
   - `jest.config.js`: add `<rootDir>/zig-pkg/` and `<rootDir>/shells/android/.gradle/` to the folders Jest skips, because the Zig and Gradle builds put copies of Ziggy there, with Ziggy's own tests in them.
4. Rename the app. Every one of these names the template, and each must name the new app instead (the Vite example used `ziggy-example-vite`, `ziggy_example_vite`, `dev.ziggy.examplevite`, `ZiggyExampleVite` and "Ziggy Vite example"):
   - `ziggy-template`, the app's name: `package.json`'s `name`, the `name` given to `addAppBackend` and `IShellApp` in `build.zig` (which names the steps `<name>-backend`, `<name>-linux`, `<name>-windows`, `<name>-dev` and `<name>-dev-host`, and the executables) and every script and doc that runs those steps or names the executables and packages.
   - `ziggy_template`, the `.name` in `build.zig.zon` and the name of the backend library (`libziggy_template.a`, `libziggy_template.so`): the Xcode projects link it, `shells/android` loads it and the sync and package scripts copy it. `addAppBackend` makes it from the app's name, with each `-` as `_`.
   - `ziggy-template-backend`, the name the backend's unit tests import the backend under: `build.zig` and `backend/src/test`.
   - `dev.ziggy.template`, the app's identifier: the Linux and Windows native apps' `app_id`, the Android `namespace` and `applicationId` in `shells/android/app/build.gradle`, the Java package of `MainActivity` (and its folder, `app/src/main/java/dev/ziggy/template`), the scripts that start or install the app by it and the bundle identifier in both Xcode projects.
   - `ZiggyTemplate`, the Xcode projects' name: the `.xcodeproj` folders, the source folders beside them, the schemes in `xcshareddata/xcschemes`, the product names and the Apple scripts that open or build them.
   - "Ziggy template", the name a user sees: window titles, the menu, `Info.plist`, `AndroidManifest.xml`, the Windows installer and the docs.
   - The Windows installer's GUIDs in `scripts/package-windows.wxs` (the `UpgradeCode` and each `Component`'s `Guid`): make new ones with `uuidgen`, or Windows treats the new app as an upgrade of the template.
5. Run `bun install`, then the unit tests and the smoke tests. They pass unchanged in a copy that is renamed and pinned to a release.

Then change what the app does: its UI, its backend's channel and task handlers, its menu, its icon and its native projects.

## The parts of an app

- **The UI** (`ui/`): the user interface, in TypeScript and HTML, built by Vite (`vite.config.ts`) into `dist`. It talks to the backend through `window.ziggy`, whose types are in `ziggy-ui`. `ui/src/lib` holds plain functions with unit tests.
- **The backend** (`backend/`): the app's Zig library. `backend/src/handlers.zig` lists the app's handlers for Ziggy: the channels the UI sends messages on, the task types it queues, the menu and the UI's query. `backend/src/lib` holds the handlers themselves. `backend/src/index.zig` is the file the backend's build starts from, and it exports Ziggy's C interface for those handlers so the native app can call them. The backend embeds the built UI, so `dist` must be built before the backend.
- **The handlers**: a channel handler answers a message from the UI on the thread that handles the UI's messages, so it must be quick. Anything slow is a task, which runs on the backend's pool of threads, reports progress with task messages and can be cancelled.
- **The native apps** (`shells/<platform>/`): the app's native project for each platform, built on the part Ziggy provides for that platform: its name, window, icon, permissions and anything only the operating system can do. The Linux and Windows native apps are Zig, built by `build.zig`. The MacOS and iOS native apps are Xcode projects, the Android native app a Gradle project, each built by the app's scripts after the backend library is built for that platform.
- **The scripts** (`scripts/`): set up, sync, build, run, open, package, distribute and clean, for each platform, each with a markdown file beside it, and the shell libraries they share in `scripts/lib`.
- **The tests**: the UI's unit tests in `ui/src/test`, the backend's in `backend/src/test` and the smoke tests in `smoke-tests`, which start the real app, built with the test hooks, and check what it shows. The template has a hello world of each.

## Commands

The commands to set up, build, run, test and package an app are in [Commands](commands.md). The `/ziggy:check` Claude Code command runs every check the machine can run and fixes what fails.

## Dev mode

Dev mode is the quickest way to work on an app. `bun run dev` starts the app's own dev server (its `dev:ui` script, Vite in the template), builds the dev host, which runs the app's backend in front of the dev server, and opens the UI in the default browser once both are up, saying what it is doing while it builds. The bundler's config has nothing of Ziggy's in it, so any bundler works the same way. From then on:

- Saving a file under `ui/` reaches the page through the dev server's own live reload. Nothing of Ziggy's is rebuilt.
- Saving a Zig file of the app or of Ziggy rebuilds the dev host and restarts it, and the page reloads once it is back. The backend starts again, so tasks that were running are gone.
- A Zig build that fails is reported in the terminal, and the dev host that was running keeps running until the next save.

The UI is the same code as in the native app and talks to the backend through the same `window.ziggy`. What only the native app can do (menus, screenshots and the app's own native calls) answers with the error `HostCallbackMissing`. File and folder dialogs work on Linux, where the dev host shows them with zenity, and answer `HostCallbackMissing` on Windows and macOS. A dropped file's path is the path of a copy the dev host saves, because a browser gives a page no file's path. The page renders in the browser's engine, so check the native app on each platform as well.

Dev mode is for development only: no native app and no release build includes it.

## See also

- [Integrating Ziggy](integrating-ziggy.md): the lines an app adds to use Ziggy, and the scripts dev mode needs in `package.json`.
- [Channels](channels.md) and [Tasks](tasks.md): the two kinds of handler.
- [Distributing your app](distributing-your-app.md): packaging, signing and Firebase App Distribution.
- [The dev host's README](../packages/ziggy/dev/README.md): what dev mode can and cannot do.
