# Ziggy architecture

Ziggy is a framework for building cross-platform apps with JavaScript/TypeScript, HTML and CSS for the user interface and Zig for everything else. The same code-base builds for Linux, Windows, macOS, Android and iOS, using each platform's system web view for the UI.

Check the [glossary](../glossary.md) to understand the jargon.

This diagram shows the main parts of a Ziggy app and how they interact:

![How the parts communicate: the UI, the native app, the backend and the OS, and the messages, responses, native calls and OS calls between them](diagrams/communication.svg)

- The native app does the the nativey things:
  - Opens the window.
  - Hosts the system web view.
  - Carries messages between the UI and the backend.
  - Draws the menus.
  - Shows dialogs.
  - Reads files dropped on the window.
- The backend hosts your Zig code to performa tasks that operate on local files, network sockets, processes, etc. Delegating heavy operations to the backend means the UI thread is never blocked doing work.

## Dev mode

In dev mode the UI runs in an ordinary browser and the dev backend takes the place of the native app. The UI and the dev backend exchange messages, message responses and events over a WebSocket.

![How the parts communicate in dev mode: the UI in a browser, the dev backend, the app's dev server and the OS](diagrams/dev-mode.svg)

[Dev mode](dev-mode.md) says how it works.

## Native apps

Ziggy provides native code for each platform and hosts your UI in a system web view. Here is what it looks like for each platform:

| Platform | Native app | Web view |
|---|---|---|
| Linux | Zig executable | WebKitGTK 4.1 with GTK 3 |
| Windows | Zig executable | WebView2 |
| MacOS | Swift | WKWebView |
| Android | Java activity, JNI entry points written in Zig | Android WebView |
| iOS | Swift | WKWebView |

## The bundled UI

The web UI is bundled and embedded in the app and served through the native app to the system web view rather than from files on disk. Each native app serves it from an address its web view treats as a secure context in which `fetch` of the UI's own files works, so the address depends on the web view:

- **Linux, macOS and iOS** (WebKitGTK and WKWebView): `ziggy-app://app/`, a scheme the native app registers with the web view. These web views do not let an app serve `http` or `https` addresses itself, so a scheme of its own is the only choice.
- **Windows and Android** (WebView2 and the Android web view): `https://ziggy-app.invalid/`, a host under `.invalid`, which can never be looked up, whose requests the native app answers itself. The Android web view cannot make a scheme of an app's own a secure context or let `fetch` load from it, so a UI served from `ziggy-app://` there would lose `crypto.subtle`, `crypto.randomUUID`, the clipboard and `fetch` of its own files. WebView2 could register `ziggy-app`, but that needs an environment options object the SDK provides only in C++, so Windows uses the same address as Android.

A UI must not depend on which address it is served from. A Content-Security-Policy in an app's UI names both origins, `ziggy-app://app` and `https://ziggy-app.invalid`.

The smoke test scenario `24-ui-address` checks on every platform that the UI is served from that platform's address, that the page is a secure context and that `localStorage`, IndexedDB, and `fetch` and `XMLHttpRequest` of the UI's own files work there.

## The message bridge

- The UI talks to the backend through `window.ziggy`, which the native app injects into the page.
- The native app passes messages to the backend through a C interface, declared and documented in `ziggy.h`.
- The backend handles message by invoking your Zig message handler.
- Your message handler sends a response back to the UI.

![How a message and its message response travel between the UI, the native app and the backend](diagrams/message-bridge.svg)

## Tasks

- Background tasks run on a pool of worker threads in the backend, so slow work never blocks the UI.
- The UI queues a task with `add-task`, can cancel it with `cancel-tasks` and hears back through `task-message` and `task-completed` events.
- A keep-alive task keeps a mobile app running in the background until it ends.
- The [Tasks](../user-guide/tasks.md) guide says how to write, queue and cancel one.

![How the UI queues a task, follows its progress, can cancel it and is told when it ends](diagrams/task-queue.svg)

## Native calls

- A native call is how the backend has the native app do something only native code can do: show a file dialog, read the operating system's version, quit, run a menu action, keep a mobile app running or take a screenshot.
- An app can add native calls of its own, which its own native code handles.
- The [Native calls](../user-guide/native-calls.md) guide says how to use them.

## Menus

- The backend describes the desktop menu once as JSON. Each desktop native app reads that description and builds a native menu from it with the platform's own menu API. A mobile device has no menu.
- The native app does the standard actions itself (quit, reload, zoom, the editing commands and the developer tools) and passes any other to the UI as a `menu-action` event.
- [Building your app](../user-guide/building-your-app.md#the-menu-and-the-window-icon) says how to write one.

## Test hooks

- Test hooks let the smoke tests drive the running app from outside, through a control connection on the loopback address.
- They are compiled in only with the `test-hooks` build option, which release builds never use.
- [Testing your app](../user-guide/testing.md) lists the commands.
