# Dependencies

Terms are defined in the [glossary](glossary.md).

Everything Ziggy and an app built on it depend on, what each one is and why it is needed. Where a version is pinned, the file that pins it is named; the version itself is in that file. `bun run setup` installs or downloads what it can on each platform, and says what is missing.

## On every platform

| Dependency | What it is | Why it is needed | Where it comes from |
|---|---|---|---|
| mise | A tool that installs the versions of other tools a project pins | Installs Zig, Bun, Node and jq at the versions `mise.toml` pins | Install it yourself, then run `mise trust` and `mise install` |
| Zig | The language and compiler of the backend and of the Linux and Windows native apps | Builds the backend, the native apps and the dev host, and runs their unit tests | mise (`mise.toml`) |
| Bun | A JavaScript runtime and package manager | Runs every `bun run` command and installs the npm packages | mise (`mise.toml`) |
| Node | A JavaScript runtime | Runs `scripts/ios-device.ts`, because Bun's sockets cannot carry native-run's connection to an iOS device | mise (`mise.toml`) |
| jq | A command line tool for reading and writing JSON | The shell scripts read and write JSON with it | mise (`mise.toml`) |
| TypeScript | JavaScript with types | Type-checks the UI (`bun run compile`) | npm (`package.json`) |
| Vite | A bundler and dev server for web pages | Builds the template's UI into `dist` and serves it in dev mode. Any other bundler can take its place | npm (`package.json`) |
| Jest and ts-jest | A test runner for JavaScript and its TypeScript support | Runs the UI's unit tests (`bun run test`) | npm (`package.json`) |
| ziggy-ui | Ziggy's TypeScript types of `window.ziggy` | Types the UI's calls to the backend | Ziggy's repository, at the app's Ziggy version |
| native-run | Ionic's library for installing and starting apps on phones | Installs and starts the app on an Android device or emulator and on a connected iPhone or iPad | npm (`package.json`) |

## Linux

| Dependency | What it is | Why it is needed | Where it comes from |
|---|---|---|---|
| GTK 3 (`libgtk-3-0`) | The Linux toolkit that draws windows and menus | The Linux native app's window and menus. The `.deb` depends on it | A system package. Only the runtime library is needed, not the development package |
| WebKitGTK 4.1 (`libwebkit2gtk-4.1-0`) | The browser engine Linux apps show web pages with | The system web view on Linux. The `.deb` depends on it | A system package |
| GStreamer plugins (`gstreamer1.0-plugins-good`, `gstreamer1.0-libav`) | GStreamer is the Linux library WebKitGTK uses to play sound and video, and these are its decoders | Only a UI that plays sound or video needs them. The `.deb` depends on them | System packages |
| zenity | A tool that shows dialogs from the command line | Dev mode's file and folder dialogs on Linux | A system package |
| Xvfb (`xvfb-run`) | A display server that draws to memory instead of a screen | The smoke tests run the app without a screen | A system package (`xvfb`) |
| zip and dpkg-deb | Tools that make a zip and a Debian package | `bun run package:linux` | System packages |

## Windows

| Dependency | What it is | Why it is needed | Where it comes from |
|---|---|---|---|
| Git Bash | The bash shell that comes with Git for Windows | Every script is a bash script | Git for Windows |
| Microsoft's C++ toolchain and the Windows SDK | Visual Studio's compiler and Windows' libraries (the "Desktop development with C++" workload of Visual Studio or its Build Tools) | The WebView2 loader is linked into the app from the SDK's static library, which is built with this toolchain | Setup installs them with winget when they are missing, which needs administrator approval |
| winget | Windows' package manager | Setup installs the C++ toolchain with it | "App Installer" from the Microsoft Store |
| WebView2 SDK | Microsoft's SDK for the Edge web view | The system web view on Windows | Setup downloads the version `scripts/fetch-webview2.sh` pins |
| WiX Toolset 3 | A tool that builds `.msi` installers | `bun run package:windows` | Setup downloads the version `scripts/fetch-wix.sh` and `scripts/windows-common.sh` pin |

Under Git Bash, the tools mise installs must be on PATH: add `%LOCALAPPDATA%\mise\shims` to PATH, or activate mise in the shell.

## macOS and iOS

| Dependency | What it is | Why it is needed | Where it comes from |
|---|---|---|---|
| macOS 12.7.6 or newer, and Xcode 14.2 or newer | Apple's operating system and its tools for building apps | Builds the macOS and iOS native apps and runs the iOS simulator | Apple |
| rsync, ditto and hdiutil | Tools for copying files and making disk images | The sync and package scripts copy the backend into the Xcode projects and make the `.dmg` | Part of macOS |

## Android

Android builds on Linux or a Mac.

| Dependency | What it is | Why it is needed | Where it comes from |
|---|---|---|---|
| JDK 17 | The Java development kit | Gradle and the Android Gradle plugin run on it, and they fail on newer JDKs | Setup installs it where it is missing |
| Android SDK | Google's tools and libraries for building Android apps, with `adb` | Builds the Android app and installs it on a device | Setup installs it where it is missing |
| Android NDK | The compilers and C libraries for Android | Zig links the backend against its C library | Setup installs the version `shells/android/variables.gradle` pins |
| Gradle and the Android Gradle plugin | Android's build tool and its Android support | Builds the Android native app | Downloaded by the Gradle wrapper, at the versions `shells/android/gradle/wrapper/gradle-wrapper.properties` and `shells/android/build.gradle` pin. The app must use the same plugin version as Ziggy's Android native app |
| curl and unzip | Tools that download and unpack files | Setup downloads and unpacks the Android SDK with them | System packages |
| An emulator or a device | | Runs the app (`bun run run:android`) and its smoke tests | Yours to start or attach |

## Dev mode and distributing

| Dependency | What it is | Why it is needed | Where it comes from |
|---|---|---|---|
| Chrome or Chromium | A web browser | Ziggy's dev mode smoke tests run the UI in it without a window, and `bun run diagrams` draws the docs' diagrams in it | Install it yourself |
| Mermaid CLI (`@mermaid-js/mermaid-cli`) | The command line tool that draws Mermaid diagrams | `bun run diagrams` draws the docs' diagrams with it | Fetched by `bunx`, at the version `scripts/render-diagrams.sh` pins |
| Firebase CLI | Google's command line tool for Firebase | `bun run distribute:android` uploads the app to Firebase App Distribution with it | Install it yourself and sign in |
