# Ziggy

Ziggy is a framework for building cross-platform apps with JavaScript/TypeScript, HTML and CSS for the user interface and Zig for everything else. One app runs on Linux, Windows, macOS, Android and iOS, using each platform's system web view.

## Why Ziggy

Electron was great, but it has had its day. Ziggy aims for small standalone executables, with small bundle sizes and high performance native code for background tasks.

## Why you might not want Ziggy

- **Each platform renders your UI with a different engine.** Ziggy uses the system web view: WebKitGTK on Linux, WebView2 (Chromium) on Windows, the Android WebView and WKWebView (WebKit) on macOS and iOS. Electron ships one copy of Chromium everywhere. With Ziggy, your HTML and CSS has to work in all of them, and you have to test it on every platform.
- **Your background code is Zig, not Node.js.** Anything outside the UI is written in Zig, so the npm packages and Node.js APIs you might use in an Electron main process are not available there.
- **Zig has not reached 1.0.** The language and its standard library still change between releases, and moving to a new Zig version can mean changing your code.
- **Linux users need the system libraries.** The `.deb` depends on the runtime libraries of GTK 3 and WebKitGTK 4.1 and on the plugins of GStreamer, which have to be installed on the user's machine. They are not bundled in the app.

## Getting started

To see what building an app with Ziggy looks like, start with the quick start.

- [Quick start](docs/quick-start.md): get an example app running and see the code behind it.
- [User guide](docs/user-guide.md): how an app is put together, and how to build your own.
- Examples, complete apps built on a released version of Ziggy:
  - [Vite example](https://github.com/ashleydavis/ziggy-example-vite): the UI built with Vite.
  - [Rsbuild example](https://github.com/ashleydavis/ziggy-example-rsbuild): the UI built with Rsbuild.
- [Developing Ziggy](docs/developing-ziggy.md): work on Ziggy itself.
- [Dependencies](docs/dependencies.md): what Ziggy and an app need on each platform, and why.
- [Glossary](docs/glossary.md): the words the guides use.

## Licence

MIT. See [LICENSE](LICENSE).
