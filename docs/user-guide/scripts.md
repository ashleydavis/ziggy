# Scripts

Terms are defined in the [glossary](../glossary.md).

`<platform>` is `linux`, `windows`, `macos`, `android` or `ios`, and each platform's commands run on that platform: Linux on Linux, Windows under Git Bash on Windows, macOS and iOS on a Mac with Xcode 14.2 or newer, Android on Linux or a Mac.

Run from the app's directory. Every app made from the template has them, and so does the template itself.

| Command | What it does |
|---|---|
| `bun run setup` | One time per machine: the Android SDK, NDK and a JDK 17 on Linux and macOS, the WebView2 SDK and WiX Toolset on Windows and a check of Xcode on macOS. |
| `bun run dev` | Runs the app in dev mode: the app's dev server (the `dev:ui` script) serves the UI, the dev backend runs the backend in front of it, rebuilt as its Zig files change, and the default browser opens the dev backend, with live reload. `zig build <name>-dev -- --no-open` does the same without opening the browser. |
| `bun run bundle:ui` | Builds the UI into `dist`, which every platform embeds. |
| `bun run sync:<platform>` | Builds what the platform's native project packages and puts it where that project expects it. |
| `bun run build:<platform>` | Builds the UI and the app. |
| `bun run <platform>` | Builds the app and runs it (on an attached emulator or device for Android, on a simulator for iOS). |
| `bun run open:<platform>` | Syncs, then opens the native project in its editor (Xcode, Android Studio). |
| `bun run package:<platform>` | Packages the release app, without the test hooks, into `out/<platform>`. |
| `bun run distribute:android` | Builds the Android app and uploads it to Firebase App Distribution for the tester group. See `scripts/distribute-android.md`. |
| `bun run clean:<platform>` | Removes the platform's build output. |
| `bun run clean` | Runs the clean for every platform this machine can clean. |
| `bun run compile` (alias `bun run c`) | Type-checks the UI. |
| `bun run compile:zig` | Builds the UI and the backend for this machine, then cross-builds the backend for every other platform and checks the Windows native app compiles. |
| `bun run test` (alias `bun run t`) | The UI's unit tests. |
| `bun run test:zig` | The backend's unit tests (`zig build test`). `zig build test -Dtest-filter=<text>`, run in the app's directory once `bun run bundle:ui` has built the UI, runs only the backend tests whose names contain the text. The option may be given more than once. |
| `bun run test:smoke` | The smoke tests on this machine's desktop platform. `bun run test:smoke -- <name>` runs one. |
| `bun run test:smoke:and` | The smoke tests on an attached Android emulator or device (the ones `ZIGGY_ANDROID_DEVICES` names, when it is set). |
| `bun run test:smoke:ios` | The smoke tests on a connected iPhone or iPad when there is one, otherwise the iOS simulator. |

## Packages

The unsigned packages `bun run package:<platform>` writes, and the script doc that says where they go and what they need:

| Platform | Packages | Script doc |
|---|---|---|
| `linux` | zip, `.deb` | `scripts/package-linux.md` |
| `windows` | zip, `.msi` installer | `scripts/package-windows.md` |
| `macos` | `.dmg`, zip | `scripts/package-macos.md` |
| `ios` | `.xcarchive`, `.ipa` | `scripts/package-ios.md` |
| `android` | `.apk` per architecture | `scripts/package-android.md` |

## See also

- [Dependencies](dependencies.md): what to install on each platform before these commands run, what each dependency is and why it is needed.
- [Dev mode](building-your-app.md#dev-mode): what `bun run dev` does as you save files.
- [Distributing your app](distributing-your-app.md): signing the packages and getting them to testers and stores.
