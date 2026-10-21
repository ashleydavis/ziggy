# Ziggy

Ziggy is a framework for building cross-platform apps with JavaScript/TypeScript, HTML and CSS for the user interface and Zig for everything else. One app runs on Linux, Windows, macOS, Android and iOS, using each platform's system web view.

Check the [glossary](docs/glossary.md) to understand the jargon.

## Why Ziggy

Electron was great, but it has had its day. Ziggy aims for small standalone executables, with small bundle sizes and high performance native code for background tasks.

Ziggy gives you full control of the native apps (like Capacitor does) so you can do almost anything you want with it.

Ziggy allows you to hit all platforms with one app and one shared UI.

## Why you might not want Ziggy

- **Each platform renders your UI with a different engine.** Ziggy uses the system web view: WebKitGTK on Linux, WebView2 (Chromium) on Windows, the Android WebView and WKWebView (WebKit) on macOS and iOS. Electron ships one copy of Chromium everywhere. With Ziggy, your HTML and CSS has to work in all of them, and you have to test it on every platform.
- **Your backend code is Zig.** The UI is JavaScript/TypeScript, the "backend" is Zig. I would love for the backend to be JS/TS as well, but it just doesn't work in the native portion of the app on mobile. Zig was chosen because it's simple (very readable if you are used to TypeScript) and it works on all platforms.
- **Linux users need the system libraries.** The `.deb` depends on the runtime libraries of GTK 3 and WebKitGTK 4.1 and on the plugins of GStreamer, which have to be installed on the user's machine. They are not bundled in the app.

## Why Bun

Ziggy uses [Bun](https://bun.sh) to install packages and run its commands.

- **Ziggy grew out of a Bun project.** Its Zig code was ported from a TypeScript app built on Electron and Capacitor, which already used Bun, so Bun came with it.
- **It manages the monorepo.** Ziggy's repository holds Ziggy's TypeScript package, the template and the test app as Bun workspaces.
- **It is good for scripting tools.** Helper scripts can be written in TypeScript and run with `bun <file>.ts`, with no build step.

## Getting started

To see what building an app with Ziggy looks like, start with the quick start.

- [Quick start](docs/quick-start.md): get an example app running and see the code behind it.
- [User guide](docs/user-guide.md): how an app is put together, and how to build your own.
- [Starting a new app](docs/user-guide/building-your-app.md#starting-a-new-app-from-the-template): have an AI coding agent, such as Claude Code, start one for you, or do it yourself.
- Examples, complete apps built on Ziggy:
  - [Vite example](https://github.com/ashleydavis/ziggy-example-vite): the UI built with Vite.
  - [Rsbuild example](https://github.com/ashleydavis/ziggy-example-rsbuild): the UI built with Rsbuild.
- [Developing Ziggy](docs/development/developing-ziggy.md): work on Ziggy itself.
- [Dependencies](docs/user-guide/dependencies.md): what an app needs on each platform, and why.
- [Glossary](docs/glossary.md): the words the guides use.

## Licence

MIT. See [LICENSE](LICENSE).
