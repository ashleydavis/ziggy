# Building your app

A new app starts from the Ziggy template (`apps/ziggy-template`), which is a complete app with a frontend, a Zig backend and a native project for each platform, with tests and scripts to build, run and package it. The copy of template is then owned by the app and as the app developer you can modify it how you like. Ziggy itself is a dependency.

Check the [glossary](glossary.md) to understand the jargon.

## Starting a new app from the template

Before you start, install the dependencies for your platform: [Dependencies](dependencies.md#installing-them).

### Creating your app with Claude

The quickest way to create your app is to have Claude (or other) do it for you.

#### 1. Create a directory for your app

Create a directory for your app called `my-app` and change into it:

```bash
mkdir my-app
cd my-app
```

#### 2. Start Claude

```bash
claude
```

#### 3. Tell Claude to create your app

> Make a new Ziggy app here by following https://github.com/ashleydavis/ziggy/releases/latest/download/agent-quick-start.md

Creating the app takes a while: it downloads the template, customizes it, installs tools with mise, then Zig and Bun dependencies.

#### 4. Run setup

If you build for Windows, Android or iOS, run setup in your app's directory, once per machine. Linux and macOS desktop do not need it.

- Windows: downloads the WebView2 SDK and installs Microsoft's C++ build tools.
- Android (on Linux or a Mac): installs the Android SDK, NDK and a JDK 17.
- iOS (on a Mac): checks Xcode and its iOS simulator.

```bash
bun run setup
```

#### 5. Build, test and run your app

Type-check, test and build your new app, one command after another.

```bash
bun run compile     # Type-checks the frontend.
bun run test        # Runs the frontend's unit tests.
bun run test:zig    # Builds the backend and runs its unit tests.
bun run test:smoke  # Builds your app and runs its smoke tests in a hidden window.
```

Run the app depending on your platform:

```bash
bun run linux    # Builds and runs your app on Linux.
bun run windows  # Builds and runs your app on Windows.
bun run macos    # Builds and runs your app on macOS.
```

Or run the frontend in your browser with dev mode, which reloads as you save. See [Dev mode](dev-mode.md).

```bash
bun run dev
```

Or build the app and run it direct from the binary:

```bash
bun run build:linux                       # Builds your app on Linux.
./native/linux/zig-out/bin/my-app         # Runs the Linux build.

bun run build:windows                       # Builds your app on Windows.
./native/windows/zig-out/my-app/my-app.exe  # Runs the Windows build.

bun run build:macos                                             # Builds your app on macOS.
open native/macos/zig-out/xcode/Build/Products/Debug/MyApp.app  # Runs the macOS build.
```

On Linux or a Mac you can also build, run and test it on Android. Start an Android emulator first (Android Studio's Device Manager creates and starts one), or plug in a phone with USB debugging on:

```bash
bun run build:android       # Builds your app for Android.
bun run android             # Builds your app, installs it on the emulator or phone and starts it.
bun run test:smoke:android  # Runs the smoke tests on the emulator or phone.
```

On a Mac you can also build, run and test it on iOS. The run and the tests use a connected iPhone or iPad if there is one, otherwise they boot an existing iOS simulator. They never create a simulator.

```bash
bun run build:ios       # Builds your app for iOS.
bun run ios             # Builds your app and runs it on a connected iPhone or iPad, otherwise on an iOS simulator.
bun run test:smoke:ios  # Runs the smoke tests on a connected iPhone or iPad, otherwise on an iOS simulator.
```

### Creating your app without Claude

1. Download `ziggy-template-<tag>.zip` from the assets of Ziggy's [latest release](https://github.com/ashleydavis/ziggy/releases/latest), where `<tag>` is the release's tag, such as `v1.2.3`. It is the template with every reference to Ziggy already pointing at that release, and Ziggy's `mise.toml`. Unpack it into your app's directory, then install the tools:

   ```bash
   unzip ziggy-template-<tag>.zip -d my-app
   cd my-app
   mise trust
   mise install
   ```

2. Search and replace the template's names with your app's, in file contents and in file and directory names:

   - `ziggy-template` with `my-app`
   - `ziggy_template` with `my_app`
   - `dev.ziggy.template` (and the directory path `dev/ziggy/template`) with your app's identifier, such as `com.example.myapp`
   - `ZiggyTemplate` with `MyApp`
   - `Ziggy template` with `My App`

3. Run `bun install`, then [build and test your new app](#building-and-testing-your-new-app).

### Building and testing your new app

Run these in your app's directory, one after another. Every test passes unchanged in a new app, so a failure means a step of making it went wrong.

```bash
bun run compile
bun run test
bun run test:zig
bun run test:smoke
```

- `bun run compile` type-checks the frontend.
- `bun run test` runs the frontend's unit tests.
- `bun run test:zig` builds the backend and runs its unit tests.
- `bun run test:smoke` builds your app and runs its smoke tests in a hidden window on this machine's desktop platform.

Then run your app and see its window, with the command for your platform:

```bash
bun run linux
bun run windows
bun run macos
```

### Putting your app on GitHub

Your app comes with GitHub Actions workflows (see [the parts of an app](../development/architecture.md)) that test it and publish a release for each platform once it is on GitHub.

1. Create an empty repository for your app on GitHub and push your app to it, following the instructions GitHub shows.

2. Watch the workflows run: open your repository on GitHub and click the **Actions** tab. Each push starts `CI`, which runs the type check, the unit tests and the build for every platform, and a `Release <platform>` workflow for each platform, which runs the smoke tests and packages your app for that platform. Click a run to see its jobs and their logs. A green tick means it passed, a red cross that it failed.

3. When a platform's workflow has passed on your default branch, its packages are in a GitHub release named after your app and the platform, on the tag `release-<platform>`. Find them on your repository's page under **Releases** in the right-hand column, or at `https://github.com/<your-account>/my-app/releases`. Each release lists the packages to download under **Assets**.

   Each push to the default branch replaces those releases with new ones. [Distributing your app](distributing-your-app.md) covers signing and getting your app to testers and stores.

Then change what the app does: its frontend, its backend's message handlers and task handlers, its menu, its icon and its native projects.

## Moving to a newer version

Run the `/ziggy:upgrade` Claude Code command in your app's directory, or do it yourself:

1. Read the new release's notes for anything your app has to change. An app made before Ziggy read `app.zon` needs one (see [The app's details](#the-apps-details)).
2. Change Ziggy's version to the new tag in `build.zig.zon` (run `zig fetch --save=ziggy "git+https://github.com/ashleydavis/ziggy.git#<tag>"`), `package.json`, `native/android/app/build.gradle` and both Xcode projects, then run `bun install`.
3. Build your app and run its tests on every platform.

## The app's details

Every app has an `app.zon` beside its `build.zig`, which gives Ziggy the app's details:

```zig
.{
    .name = "my-app",
    .title = "My App",
    .version = "1.2.0",
}
```

| Field | Required | What it is for |
|---|---|---|
| `name` | Yes | The app's name: its log files are `my-app-<start time>.log`. |
| `title` | Yes | The app's name as people read it, which heads its log files. |
| `version` | No | The app's version, which its log files give. A release build writes the release's version here before building. |

Ziggy's build reads it with Zig's ZON parser whenever the app's `build.zig` calls `ziggy_build.dependency`. An app with no `app.zon`, one that does not parse, one missing `name` or `title` or one with a field Ziggy does not know does not build, and the error says why. The template's is `ziggy-template` and `Ziggy template`, which the search and replace of a new app changes with the rest of its names. See [Logging](logging.md) for how the log files use it.

## The window icon

The desktop menu is in [Menus](menus.md).

The window icon:

- **Linux:** `AppConfig.icon_png` holds the bytes of a PNG file, which the app's build gives to its main file with an `app-icon` import.
- **Windows:** `AppConfig.icon_resource` is the number of an icon in the executable's resources, which the app's build adds from a resource script.
- **macOS, iOS and Android:** the icon belongs to the app's bundle, from an asset catalog or the launcher icons in the app's resources.

An app with no icon passes null and shows the desktop's generic one.

## See also

- [Messages](messages.md): sending messages from the frontend and handling them in the backend.
- [Tasks](tasks.md): running slow work in the background without blocking the frontend.
- [Menus](menus.md): the desktop menu and its keyboard shortcuts.
- [Native calls](native-calls.md): how to show native dialogs and call native functions.
- [Testing your app](testing.md): adding unit tests and smoke tests to your app.
- [Dev mode](dev-mode.md): running the frontend in a browser that reloads as you save.
- [Scripts](scripts.md): every script to set up, build, run, test and package your app.
- [Claude Code commands](claude-code-commands.md): the commands that extend, check and upgrade your app, such as `/ziggy:check`.
- [Distributing your app](distributing-your-app.md): packaging, signing and Firebase App Distribution.
