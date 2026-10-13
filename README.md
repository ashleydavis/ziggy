# Ziggy

Ziggy is a framework for building cross-platform apps with JavaScript/TypeScript, HTML and CSS for the user interface and Zig for everything else. One app runs on Linux, Windows, macOS, Android and iOS, using each platform's system web view.

## Why Ziggy

Electron was great, but it has had its day. Ziggy aims for small standalone executables, with small bundle sizes and high performance native code for background tasks.

## Why you might not want Ziggy

- **Each platform renders your UI with a different engine.** Ziggy uses the system web view: WebKitGTK on Linux, WebView2 (Chromium) on Windows, the Android WebView and WKWebView (WebKit) on macOS and iOS. Electron ships one copy of Chromium everywhere. With Ziggy, your HTML and CSS has to work in all of them, and you have to test it on every platform.
- **Your background code is Zig, not Node.js.** Anything outside the UI is written in Zig, so the npm packages and Node.js APIs you might use in an Electron main process are not available there.
- **Zig has not reached 1.0.** The language and its standard library still change between releases, and moving to a new Zig version can mean changing your code.
- **Linux users need the system libraries.** The `.deb` depends on the GTK 3 and WebKitGTK 4.1 runtime libraries, which have to be installed on the user's machine. They are not bundled in the app.

## What is in this repository

This repository holds:

- **Ziggy**, the package an app is built on, in `packages/ziggy`: the Zig core with its task queue, the native app for each platform and the TypeScript types of `window.ziggy` for the UI.
- **The Ziggy template**, in `apps/ziggy-template`: a small complete app that shows how to use the package, with smoke tests on every platform. A new app starts as a copy of it.

Nothing is published to npm or any other registry. An app uses Ziggy either from a checkout of this repository, by a local path, or from a version tag of this repository, by its git URL.

## Guides

- [Integrating Ziggy](docs/integrating-ziggy.md): the lines an app adds to use Ziggy, from a local path or from a version tag, and how to move to a newer tag.
- [Building your app](docs/building-your-app.md): starting a new app from the template, the parts of an app and the commands to set up, build, run and test it on each platform.
- [Tasks](docs/tasks.md): how the task queue works, with a diagram, and how to write, register, queue, follow and cancel a task.
- [Claude Code commands](docs/claude-code-commands.md): the slash commands that start a new app on Ziggy, check it, add channels and tasks to it and move it to a newer Ziggy, and how to install them.
- [Distributing your app](docs/distributing-your-app.md): packaging, signing and getting a build to testers and stores, on each platform.
- [Releasing Ziggy](docs/releasing-ziggy.md): what the release workflow does on each push, and how a version of the package is released.
- [Packages](docs/packages.md): each folder of the package, its language and why it is built separately.
- [Architecture](docs/architecture.md): how the parts fit, the message protocol, tasks, channels, host callbacks, menus and test hooks.

## Getting started

The tools are pinned in `mise.toml`. Install them with `mise install`, then the dependencies with `bun install`, then the platform toolchains with `bun run setup` (the Android SDK and NDK on Linux and MacOS, the WebView2 SDK and WiX Toolset on Windows and a check of Xcode on MacOS).

| Command | What it does |
|---|---|
| `bun run test` | The TypeScript unit tests: `ziggy-ui` and the template's UI. |
| `bun run test:zig` | Every Zig test (`zig build test`): Ziggy's core and its task queue, the parts of the Linux and Windows native apps that need no platform, the dev host and the template's core. It builds the template's UI first. |
| `bun run test:android-shell` | The JUnit tests of the Android native app, on this machine's JVM. |
| `bun run compile` | Type-checks the TypeScript. |
| `bun run compile:zig` | Builds the template's core, cross-builds it for every platform and compiles the Windows native app. |
| `bun run test:ziggy-template` | The template's smoke tests on this machine's desktop platform. |
| `bun run test:ziggy-template:and` | The template's smoke tests on an attached Android emulator or device. |
| `bun run test:ziggy-template:ios` | The template's smoke tests on the iOS simulator (MacOS only). |
| `bun run test:ziggy-template:dev` | The template's smoke tests in dev mode, in a headless Chrome or Chromium. |
| `bun run dev:ziggy-template` | Runs the template in dev mode: its UI in the default browser, rebuilt as its files change. |
| `bun run run:ziggy-template:<platform>` | Builds the template and runs it. |

The template's [README](apps/ziggy-template/README.md) has the rest of its commands.

## Glossary

- **The app**: everything you build and ship with Ziggy: the UI, the core and the native app together.
- **The UI**: the app's HTML, CSS and JavaScript/TypeScript, which runs in the system web view. The native menus and file dialogs are not part of it.
- **The core**: the app's Zig code together with Ziggy's core library. It is the same code on every platform, handles messages from the UI, runs tasks and never touches a window.
- **The native app**: the part of the app written separately for each platform. It opens the window, hosts the system web view, draws the menus and file dialogs and passes messages between the UI and the core. Ziggy provides most of it: Zig on Linux and Windows, Swift on macOS and iOS, Java on Android.
- **The system web view**: the browser engine each platform provides for showing web content: WebKitGTK on Linux, WebView2 on Windows, the Android WebView and WKWebView on macOS and iOS.
- **Dev mode**: running an app while it is developed, with its UI in an ordinary browser served by its bundler's dev server, with live reload, and its core in the dev host, rebuilt as its Zig files change. No native app and no release build includes it. See the [dev host's README](packages/ziggy/dev/README.md).

## Licence

MIT. See [LICENSE](LICENSE).
