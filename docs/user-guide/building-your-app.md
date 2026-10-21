# Building your app

A new app starts as a copy of the Ziggy template (`apps/ziggy-template`), which is a complete app with a UI, a Zig backend, a native project for each platform, tests and scripts to build, run and package it. The copy is the app's own code from then on. Ziggy itself is never copied: the app takes it as a dependency. Terms are defined in the [glossary](../glossary.md).

## Starting a new app from the template

Before you start, install [mise](https://mise.jdx.dev), then what your platform needs. [Dependencies](dependencies.md) lists everything an app needs and why.

- **Linux:** install the libraries the app runs on and the tools its tests use:

  ```bash
  sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0 gstreamer1.0-plugins-good gstreamer1.0-libav xvfb
  ```

- **Windows:** the scripts that set up, build, run, test and package your app are bash scripts, so install [Git for Windows](https://gitforwindows.org) for its Git Bash shell, add `%LOCALAPPDATA%\mise\shims` to PATH and run every command in Git Bash.
- **macOS:** install Xcode.

The quickest way is to have an AI coding agent, such as Claude Code, do these steps for you. It asks for the app's names as it goes.

1. Create a directory for your app called `my-app` and go into it:

   ```bash
   mkdir my-app
   cd my-app
   ```

2. Start Claude Code (or the agent of your choice) there:

   ```bash
   claude
   ```

3. Tell it:

   > Make a new Ziggy app here by following https://github.com/ashleydavis/ziggy/releases/latest/download/agent-quick-start.md

   Making the app takes a while: the agent installs Zig, Bun, Node and jq with mise (the common way to install the exact versions of the tools a project uses) and installs the app's Bun and Zig dependencies (Ziggy among them).

4. When the agent is done, type-check, test and build your new app, one command after another. On Windows, run `bun run setup` first, once per machine: it downloads the WebView2 SDK and installs Microsoft's C++ build tools.

   ```bash
   bun run compile     # Type-checks the UI.
   bun run test        # Runs the UI's unit tests.
   bun run test:zig    # Builds the backend and runs its unit tests.
   bun run test:smoke  # Builds your app and runs its smoke tests in a hidden window.
   ```

   Every test passes unchanged in a new app, so a failure means a step of making it went wrong. Then run it and see its window, with the command for your platform:

   ```bash
   bun run linux    # Builds and runs your app on Linux.
   bun run windows  # Builds and runs your app on Windows.
   bun run macos    # Builds and runs your app on macOS.
   ```

   To build without running, or to run what you last built without building it again:

   ```bash
   bun run build:linux                       # Builds your app on Linux.
   ./native/linux/zig-out/bin/my-app         # Runs the Linux build.

   bun run build:windows                     # Builds your app on Windows.
   ./native/windows/zig-out/my-app/my-app.exe  # Runs the Windows build.

   bun run build:macos                       # Builds your app on macOS.
   open native/macos/zig-out/xcode/Build/Products/Debug/MyApp.app  # Runs the macOS build.
   ```

   On Linux or a Mac you can also build, run and test it on Android. Setup installs the Android SDK, NDK and a JDK 17. It does not make an emulator: start one (Android Studio's Device Manager makes and starts them) or plug in a phone with USB debugging on before you run or test:

   ```bash
   bun run setup           # Installs the Android tools. Once per machine.
   bun run build:android   # Builds your app for Android.
   bun run android     # Builds your app, installs it on the emulator or phone and starts it.
   bun run test:smoke:and  # Runs the smoke tests on the emulator or phone.
   ```

   On a Mac you can also build, run and test it on iOS. Setup checks Xcode and its iOS simulator, and the run and tests start a simulator themselves:

   ```bash
   bun run setup           # Checks Xcode and its iOS simulator. Once per machine.
   bun run build:ios       # Builds your app for iOS.
   bun run ios         # Builds your app and runs it on an iOS simulator.
   bun run test:smoke:ios  # Runs the smoke tests on a connected iPhone or iPad, otherwise on an iOS simulator.
   ```

To do it yourself:

1. Find Ziggy's latest release, the highest version tag of its repository. The tag is the last part of the line this prints (`refs/tags/<tag>`):

   ```bash
   git ls-remote --tags --refs --sort=-version:refname https://github.com/ashleydavis/ziggy 'v*' | head -n 1
   ```

2. In the new app's empty directory, download the template and Ziggy's `mise.toml` of that release, and install the tools. The archive holds only the files in the repository, so nothing a build writes comes with it:

   ```bash
   curl -fsSL https://github.com/ashleydavis/ziggy/archive/refs/tags/<tag>.tar.gz | tar -xz --strip-components=3 --wildcards '*/apps/ziggy-template/*'
   curl -fsSL -o mise.toml https://raw.githubusercontent.com/ashleydavis/ziggy/<tag>/mise.toml
   mise trust
   mise install
   ```

3. Pin every part to that release, all naming the same tag:
   - `build.zig.zon`: replace the `ziggy` dependency's `.path` with the repository's URL and hash at the tag. This writes both:

     ```bash
     zig fetch --save=ziggy "git+https://github.com/ashleydavis/ziggy.git#<tag>"
     ```

     The dependency must keep the name `ziggy`, because Ziggy's build functions look it up by that name. Delete the `.fingerprint` line; `zig build` then prints a new one, which goes back in.
   - `package.json`: replace `workspace:*` for `ziggy-ui` with `"git+https://github.com/ashleydavis/ziggy.git#<tag>"`.
   - `native/android/app/build.gradle`: set the version of `dev.ziggy:ziggy-native-android` to the tag:

     ```groovy
     implementation 'dev.ziggy:ziggy-native-android:<tag>'
     ```

   - `native/android/settings.gradle`: replace the `includeBuild(...)` block with the repository as a source dependency, which Gradle checks out at the tag and builds:

     ```groovy
     sourceControl {
         gitRepository(uri('https://github.com/ashleydavis/ziggy.git')) {
             producesModule('dev.ziggy:ziggy-native-android')
             rootDir = 'packages/ziggy/native/android'
         }
     }
     ```

   - `native/macos/ZiggyTemplate.xcodeproj` and `native/ios/ZiggyTemplate.xcodeproj`: in Xcode, remove the folder reference to Ziggy's `macos` or `ios` package, then File > Add Package Dependencies with the URL `https://github.com/ashleydavis/ziggy`, the rule Exact Version with the tag without its `v` (`v1.2.3` is `1.2.3`) and the product `ZiggyNativeMacOS` or `ZiggyNativeIOS`.
   - `jest.config.js`: add `<rootDir>/zig-pkg/` and `<rootDir>/native/android/.gradle/` to the directories Jest skips, because the Zig and Gradle builds put copies of Ziggy there, with Ziggy's own tests in them.
4. Rename the app. Every one of these names the template, and each must name the new app instead (the Vite example used `ziggy-example-vite`, `ziggy_example_vite`, `dev.ziggy.examplevite`, `ZiggyExampleVite` and "Ziggy Vite example"):
   - `ziggy-template`, the app's name: `package.json`'s `name`, the `name` given to `addAppBackend` and `IShellApp` in `build.zig` (which names the steps `<name>-backend`, `<name>-linux`, `<name>-windows`, `<name>-dev` and `<name>-dev-host`, and the executables) and every script and doc that runs those steps or names the executables and packages.
   - `ziggy_template`, the `.name` in `build.zig.zon` and the name of the backend library (`libziggy_template.a`, `libziggy_template.so`): the Xcode projects link it, `native/android` loads it and the sync and package scripts copy it. `addAppBackend` makes it from the app's name, with each `-` as `_`.
   - `ziggy-template-backend`, the name the backend's unit tests import the backend under: `build.zig` and `backend/src/test`.
   - `dev.ziggy.template`, the app's identifier: the Linux and Windows native apps' `app_id`, the Android `namespace` and `applicationId` in `native/android/app/build.gradle`, the Java package of `MainActivity` (and its directory, `app/src/main/java/dev/ziggy/template`), the scripts that start or install the app by it and the bundle identifier in both Xcode projects.
   - `ZiggyTemplate`, the Xcode projects' name: the `.xcodeproj` directories, the source directories beside them, the schemes in `xcshareddata/xcschemes`, the product names and the Apple scripts that open or build them.
   - "Ziggy template", the name a user sees: window titles, the menu, `Info.plist`, `AndroidManifest.xml`, the Windows installer and the docs.
   - The Windows installer's GUIDs in `scripts/package-windows.wxs` (the `UpgradeCode` and each `Component`'s `Guid`): make new ones with `uuidgen`, or Windows treats the new app as an upgrade of the template.
5. Run `bun install`, then [build and test your new app](#building-and-testing-your-new-app).
6. Make the app a git repository and commit it. The template's `.gitignore` keeps what builds and tests write out of it:

   ```bash
   git init
   git add .
   git commit -m "Started the app from the Ziggy template <tag>"
   ```

### Building and testing your new app

Run these in your app's directory, one after another. Every test passes unchanged in a new app, so a failure means a step of making it went wrong.

```bash
bun run compile
bun run test
bun run test:zig
bun run test:smoke
```

- `bun run compile` type-checks the UI.
- `bun run test` runs the UI's unit tests.
- `bun run test:zig` builds the backend and runs its unit tests.
- `bun run test:smoke` builds your app and runs its smoke tests in a hidden window on this machine's desktop platform.

Then run your app and see its window, with the command for your platform:

```bash
bun run linux
bun run windows
bun run macos
```

### Putting your app on GitHub

Your app comes with GitHub Actions workflows (see [the parts of an app](#the-parts-of-an-app)) that test it and publish a release for each platform once it is on GitHub.

1. Create an empty repository for it at https://github.com/new: give it your app's name and leave "Add a README file", ".gitignore" and "license" unset, because your app already has its own files. Then push your app to it, using the address GitHub shows on the new repository's page:

   ```bash
   git remote add origin git@github.com:<your-account>/my-app.git
   git push -u origin HEAD
   ```

2. Watch the workflows run: open your repository on GitHub and click the **Actions** tab. Each push starts `CI`, which runs the type check, the unit tests and the build for every platform, and a `Release <platform>` workflow for each platform, which runs the smoke tests and packages your app for that platform. Click a run to see its jobs and their logs. A green tick means it passed, a red cross that it failed.

3. When a platform's workflow has passed on your default branch, its packages are in a GitHub release named after your app and the platform, on the tag `release-<platform>`. Find them on your repository's page under **Releases** in the right-hand column, or at `https://github.com/<your-account>/my-app/releases`. Each release lists the packages to download under **Assets**.

   Each push to the default branch replaces those releases with new ones. [Distributing your app](distributing-your-app.md) covers signing and getting your app to testers and stores.

Then change what the app does: its UI, its backend's message handlers and task handlers, its menu, its icon and its native projects.

## Moving to a newer version

The `/ziggy:upgrade` Claude Code command follows these steps for an app.

1. Read the release notes of the new version and the changes to the guides, for anything an app has to change.
2. In `build.zig.zon`, run `zig fetch --save=ziggy "git+https://github.com/ashleydavis/ziggy.git#<tag>"` with the new tag, which replaces the URL and the hash.
3. In each Xcode project, change the package's exact version.
4. In `native/android/app/build.gradle`, change the version of `dev.ziggy:ziggy-native-android` to the new tag.
5. In `package.json`, change the tag after `#`, and run `bun install`.
6. Build the app and run its unit tests and smoke tests on every platform.

## The parts of an app

- **The UI** (`ui/`): the user interface, in TypeScript and HTML, built by Vite (`vite.config.ts`) into `dist`, which must hold an `index.html`. The template's Vite config writes relative paths (`base: './'`) and a classic script instead of a module script, and another bundler must do the same. It talks to the backend through `window.ziggy`, whose types are in `ziggy-ui`. `ui/src/lib` holds plain functions with unit tests. The UI is served from `ziggy-app://app/` on Linux, macOS and iOS and from `https://ziggy-app.invalid/` on Windows and Android, so it must not depend on its address, and a Content-Security-Policy names both (see [the bundled UI](../development/architecture.md#the-bundled-ui)).
- **The backend** (`backend/`): the app's Zig library. `backend/src/app.zig` declares the app to Ziggy with `ziggy.core.App`: each message the UI sends with its handler, each task type with its handler, the menu, the built UI and the UI's query (see [Declaring the app](messages.md#declaring-the-app)). `backend/src/lib` holds the handlers themselves. `app.zig` is the `backend_source_file` the app's `build.zig` gives `addAppBackend`, and Ziggy's build exports Ziggy's C interface for the app it declares, so the native app can call it. The app writes no exports of its own. It is built with Ziggy's core library into one library: a static library on every platform except Android, and a shared library on Android. The backend embeds the built UI, so `dist` must be built before the backend, and a changed UI file rebuilds the backend.
- **The handlers**: a message handler runs for each message of its name from the UI on the thread that handles the UI's messages, so it must be quick. Anything slow is a task, which runs on the backend's pool of threads, reports progress with task messages and can be cancelled.
- **The native apps** (`native/<platform>/`): the app's native project for each platform, built on the part Ziggy provides for that platform: its name, window, icon, permissions and anything only the operating system can do. The Linux and Windows native apps are Zig, built by `build.zig`. The MacOS and iOS native apps are Xcode projects, the Android native app a Gradle project, each built by the app's scripts after the backend library is built for that platform. The Android project must use the same version of the Android Gradle plugin as Ziggy's Android native app (see `packages/ziggy/native/android/build.gradle`), because Gradle does not allow two versions of it in one build, and its `minSdkVersion` must be at least Ziggy's.
- **The scripts** (`scripts/`): set up, sync, build, run, open, package, distribute and clean, for each platform, each with a markdown file beside it, and the shell libraries they share in `scripts/lib`.
- **The tests**: the UI's unit tests in `ui/src/test`, the backend's in `backend/src/test` and the smoke tests in `smoke-tests`, which start the real app, built with the test hooks, and check what it shows. The template has a hello world of each.
- **The workflows** (`.github/workflows`): GitHub Actions workflows that run once the app is pushed to GitHub. `ci.yml` runs on every push: the type check, the UI's and the backend's unit tests and the build of the backend for every platform. Each platform has a `release-<platform>.yml` that, on every push, runs the smoke tests and packages the app for that platform (`release-macos-x64.yml` only packages it). When those pass on the default branch, it publishes the packages as a GitHub release on the tag `release-<platform>`, replacing the one before.

## The menu and the window icon

The app gives Ziggy its desktop menu as a Zig constant, a `[]const ziggy.menu.Menu`, passed to its `ziggy.core.App` as `.menu` (`&.{}` for none). Each menu has a `label` and its `items`. An item is `ziggy.menu.separator`, a submenu with a `label` and its own `items` or an item with a `label`, an optional `accelerator` (its shortcut) and what it runs in `run`. The template's is in `backend/src/lib/menu.zig`. A small one:

```zig
const ziggy = @import("ziggy-core");
const menu_functions = @import("menu-functions.zig");

pub const menu: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .label = "Export",
                .name = "export",
                .accelerator = "CmdOrCtrl+E",
                .run = .{
                    .zig = menu_functions.exportFile,
                },
            },
            .{
                .label = "About",
                .name = "about",
                .run = .ui,
            },
            ziggy.menu.separator,
            .{
                .label = "Quit",
                .accelerator = "CmdOrCtrl+Q",
                .run = .{
                    .standard = .quit,
                },
            },
        },
    },
};
```

An item runs one of three things:

- **`.standard`**: an action the native app does itself. The actions are `quit`, `close-window`, `reload`, `toggle-devtools`, `toggle-fullscreen`, `zoom-in`, `zoom-out`, `zoom-reset`, `undo`, `redo`, `cut`, `copy`, `paste`, `select-all` and `focus-window` (the `ziggy.menu.StandardAction` enum). The developer tools open with `toggle-devtools` in every build, release included. A standard item has no `.name`.
- **`.zig`**: a Zig function of the app's, `fn (core: *ziggy.core.Core, arena: std.mem.Allocator) anyerror!void`, which the core calls. It runs on the thread that handles messages, like a message handler, so it must be quick: slow work queues a task from it. An error it returns is reported as a `core-error` system event, which the UI hears through `window.ziggy.onCoreError`.
- **`.ui`**: the UI, which receives the app event `{"type": "menu", "item": "<name>"}` through `window.ziggy.onEvent` (typed as `IMenuEvent` in `ziggy-ui`) and decides what it means. An app must not send an event of its own with `type` set to `"menu"`: the UI could not tell it from a menu item.

Every `.zig` and `.ui` item must have a `.name`. It is how the core finds the item when the native app passes on the choice. A `.ui` item's name is the `item` of its event.

```ts
window.ziggy.onEvent<IMenuEvent>(event => {
    if (event.type === "menu" && event.item === "about") {
        ...
    }
});
```

A shortcut is modifiers and a key joined by plus signs, such as `CmdOrCtrl+Shift+I`, `F12` or `CmdOrCtrl+Plus`. `CmdOrCtrl` is Command on macOS and Control elsewhere. Shortcuts work wherever the focus is, including inside the web view. A mobile device has no menu.

`ziggy.core.App` checks the menu when the app is built. The build fails with a message naming the item when:

- an item is not a separator or a submenu and has no `run`
- a submenu has a `run` or a `name`
- a separator has a `run`, `items`, `name` or `accelerator` (use `ziggy.menu.separator`)
- a `.zig` or `.ui` item has no name, an empty name or the name of a standard action, such as `quit`
- a `.standard` item has a name
- two items have the same name or the same shortcut
- a shortcut does not parse

The window icon:

- **Linux:** `AppConfig.icon_png` holds the bytes of a PNG file, which the app's build gives to its main file with an `app-icon` import.
- **Windows:** `AppConfig.icon_resource` is the number of an icon in the executable's resources, which the app's build adds from a resource script.
- **macOS, iOS and Android:** the icon belongs to the app's bundle, from an asset catalog or the launcher icons in the app's resources.

An app with no icon passes null and shows the desktop's generic one.

## Keeping state in the backend

An app that has to remember things while it runs (whether a database is open, a timer) gives Ziggy a `state` in its `ziggy.core.App`:

- `create` runs once the task runner is running. Ziggy holds the value it returns and hands it to the message handlers as `Core.app_state` and to a task as `TaskContext.appState()`. The app casts it back to its own type.
- `stop` runs first when the backend is destroyed, while tasks can still be queued, so a thread the state owns can end.
- `destroy` runs last, after the task runner has stopped, so nothing a running task reads is gone while it runs.

An app that has to know how every task ended, and every message a task sends, gives `on_task_end` and `on_task_message`. They are called after the UI has been told, from the thread the event happened on, with no lock held, and what they are given is valid only during the call. Cancelling a source from inside one ends tasks on the same thread, so an app must not hold a lock of its own while it cancels.

## Commands

The scripts to set up, build, run, test and package an app are in [Scripts](scripts.md). The `/ziggy:check` Claude Code command runs every check the machine can run and fixes what fails.

## Dev mode

Dev mode is the quickest way to work on an app. `bun run dev` starts the app's own dev server (its `dev:ui` script, Vite in the template), builds the dev backend, which runs the app's backend in front of the dev server, and opens the UI in the default browser once both are up, saying what it is doing while it builds. The bundler's config has nothing of Ziggy's in it, so any bundler works the same way. From then on:

- Saving a file under `ui/` reaches the page through the dev server's own live reload. Nothing of Ziggy's is rebuilt.
- Saving a Zig file of the app or of Ziggy rebuilds the dev backend and restarts it, and the page reloads once it is back. The backend starts again, so tasks that were running are gone.
- A Zig build that fails is reported in the terminal, and the dev backend that was running keeps running until the next save.

The UI is the same code as in the native app and talks to the backend through the same `window.ziggy`. What only the native app can do (menus, screenshots and the app's own native calls) fails with the error `HostCallbackMissing`. File and directory dialogs work on Linux, where the dev backend shows them with zenity, and fail with `HostCallbackMissing` on Windows and macOS. A dropped file's path is the path of a copy the dev backend saves, because a browser gives a page no file's path. The page renders in the browser's engine, so check the native app on each platform as well.

Dev mode needs two scripts in the app's `package.json`, which the template has:

```json
"dev": "zig build my-app-dev",
"dev:ui": "vite"
```

`dev:ui` runs the bundler's dev server (`rsbuild dev` for Rsbuild), and the supervisor gives it `--port <port> --host 127.0.0.1`.

Dev mode is for development only: no native app and no release build includes it.

## See also

- [Messages](messages.md) and [Tasks](tasks.md): the two kinds of handler.
- [Native calls](native-calls.md): dialogs and the app's own calls into its native app.
- [Testing your app](testing.md): the test hooks the smoke tests drive the app through.
- [Distributing your app](distributing-your-app.md): packaging, signing and Firebase App Distribution.
