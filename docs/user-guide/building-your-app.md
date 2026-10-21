# Building your app

A new app starts as a copy of the Ziggy template (`apps/ziggy-template`), which is a complete app with a UI, a Zig backend, a native project for each platform, tests and scripts to build, run and package it. The copy is the app's own code from then on. Ziggy itself is never copied: the app takes it as a dependency. Terms are defined in the [glossary](../glossary.md).

## Starting a new app from the template

The quickest way is the `/ziggy:new` Claude Code command, which does these steps for you and asks for the app's names as it goes. [Claude Code commands](claude-code-commands.md) says how to get it.

Without the command:

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
5. Run `bun install`, then the unit tests and the smoke tests. They pass unchanged in a copy that is renamed and pinned to a release.

Then change what the app does: its UI, its backend's channel and task handlers, its menu, its icon and its native projects.

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
- **The backend** (`backend/`): the app's Zig library. `backend/src/handlers.zig` lists the app's handlers for Ziggy: the channels the UI sends messages on, the task types it queues, the menu and the UI's query. `backend/src/lib` holds the handlers themselves. `backend/src/index.zig` is the file the backend's build starts from, and it exports Ziggy's C interface for those handlers so the native app can call them. It is built with Ziggy's core library into one library: a static library on every platform except Android, and a shared library on Android. The backend embeds the built UI, so `dist` must be built before the backend, and a changed UI file rebuilds the backend.
- **The handlers**: a channel handler runs for a message from the UI on the thread that handles the UI's messages, so it must be quick. Anything slow is a task, which runs on the backend's pool of threads, reports progress with task messages and can be cancelled.
- **The native apps** (`native/<platform>/`): the app's native project for each platform, built on the part Ziggy provides for that platform: its name, window, icon, permissions and anything only the operating system can do. The Linux and Windows native apps are Zig, built by `build.zig`. The MacOS and iOS native apps are Xcode projects, the Android native app a Gradle project, each built by the app's scripts after the backend library is built for that platform. The Android project must use the same version of the Android Gradle plugin as Ziggy's Android native app (see `packages/ziggy/native/android/build.gradle`), because Gradle does not allow two versions of it in one build, and its `minSdkVersion` must be at least Ziggy's.
- **The scripts** (`scripts/`): set up, sync, build, run, open, package, distribute and clean, for each platform, each with a markdown file beside it, and the shell libraries they share in `scripts/lib`.
- **The tests**: the UI's unit tests in `ui/src/test`, the backend's in `backend/src/test` and the smoke tests in `smoke-tests`, which start the real app, built with the test hooks, and check what it shows. The template has a hello world of each.

## The menu and the window icon

The app gives Ziggy its desktop menu as JSON text in `menu_json` of its handlers: an array of menus, each `{"label", "items"}`, where an item is `{"label", "action", "accelerator"}` or `{"separator": true}` and may hold its own `"items"` for a submenu. A shortcut is modifiers and a key joined by plus signs, such as `CmdOrCtrl+Shift+I`, `F12` or `CmdOrCtrl+Plus`. `CmdOrCtrl` is Command on macOS and Control elsewhere. Shortcuts work wherever the focus is, including inside the web view.

The native app does these actions itself: `quit`, `close-window`, `reload`, `toggle-devtools`, `toggle-fullscreen`, `zoom-in`, `zoom-out`, `zoom-reset`, `undo`, `redo`, `cut`, `copy`, `paste` and `select-all`. Any other action reaches the UI as a `menu-action` event, `{"action": "<action>"}`, and the UI decides what it means. The developer tools open with `toggle-devtools` in every build, release included. A mobile device has no menu.

The window icon:

- **Linux:** `AppConfig.icon_png` holds the bytes of a PNG file, which the app's build gives to its main file with an `app-icon` import.
- **Windows:** `AppConfig.icon_resource` is the number of an icon in the executable's resources, which the app's build adds from a resource script.
- **macOS, iOS and Android:** the icon belongs to the app's bundle, from an asset catalog or the launcher icons in the app's resources.

An app with no icon passes null and shows the desktop's generic one.

## Keeping state in the backend

An app that has to remember things while it runs (whether a database is open, a timer) gives Ziggy a `state` in its handlers:

- `create` runs once the task runner is running. Ziggy holds the value it returns and hands it to a channel handler as `Core.app_state` and to a task as `TaskContext.appState()`. The app casts it back to its own type.
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

- [Channels](channels.md) and [Tasks](tasks.md): the two kinds of handler.
- [Native calls](native-calls.md): dialogs and the app's own calls into its native app.
- [Testing your app](testing.md): the test hooks the smoke tests drive the app through.
- [Distributing your app](distributing-your-app.md): packaging, signing and Firebase App Distribution.
