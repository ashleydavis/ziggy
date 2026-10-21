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
- The native app passes messages to the backend through a C interface, declared and documented in `ziggy.h`. Every native app hands every message to the one entry point, `ziggy_post_message` (`Core.postMessage` in the core).
- There are two kinds of message, kept apart from end to end. An app message belongs to the app: the backend handles it by calling the Zig handler your app registered for its name. A system message belongs to Ziggy itself (tasks, the platform, menu actions, dropped files and the test hooks): the backend handles it with Ziggy's own handlers and your handlers never see it.
- What your handler returns is sent back to the UI as the message response.

![How a message and its message response travel between the UI, the native app and the backend](diagrams/message-bridge.svg)

Each message, message response and event is the JSON text of one object. The native app carries it between the web view and the backend without reading it, except to post a menu action of its own:

| What | From | Laid out like |
|---|---|---|
| An app message | The UI | `{"kind": "app", "id": 1, "name": "<message name>", "data": ...}`, or `{"kind": "app", "name": "<message name>", "data": ...}` for one sent with `send`, which gets no message response |
| A system message | The UI script or the native app | `{"kind": "system", "id": 1, "name": "<name>", "data": ...}`, with no `id` when it gets no message response |
| A message response, of either kind | The backend | `{"id": 1, "ok": true, "data": ...}`, or `{"id": 1, "ok": false, "error": "<text>"}` when the message failed |
| An app event | The backend | `{"kind": "app", "data": ...}`, sent by `core.sendEvent` |
| A system event | The backend | `{"kind": "system", "name": "<name>", "data": ...}` |

The `kind` field says which kind a message or event is:

- `Core.postMessage` reads the `kind` and does nothing else. It passes an app message to `postAppMessage`, which looks its name up in the registry of app messages. It passes a system message to `postSystemMessage`, which looks its name up in the registry of system messages. See "Registries and handlers" below.
- A message that is not a JSON object, or has no `kind` or any other value, is refused as `InvalidMessage` and reported as a `core-error` system event.
- The backend refuses an app message with no name, an empty name or a name that is not a string, with `MissingMessageName` and a name no app message is registered under with `UnknownMessageName`, before any handler runs. A system message with no name is `InvalidMessage`.
- The UI script hands an app event to the `onEvent` listeners and a system event only to Ziggy's listener for its name, so an app never sees Ziggy's own traffic.
- `window.ziggy` has no call that sends a system message of the app's choosing: each of Ziggy's own calls names its own message.
- The `id` is any JSON value the UI chooses, and the message response carries it back unchanged.

## Registries and handlers

The core keeps two registries of message handlers by name, one of app messages and one of system messages (`message-registry.zig`). The task runner keeps the task types. Each can be added to at any point while the core runs, from any thread, while messages are being handled. Registering a name that is registered already fails loudly and prints the name: `DuplicateMessage` for a message, `DuplicateTaskType` for a task type.

- **App messages and task types.** The app declares them in `ziggy.core.App` (`app.zig`), which checks every handler when the app is built and makes the lists the core registers when it is created. The app adds more later with `core.registerMessage` and `core.registerTask`. `registerMessage` only ever adds to the registry of app messages.
- **System messages.** There is no list of them. Each part of Ziggy registers its own while the core is being created, from its file under `system-messages/`: the platform `get-platform`, the menu `menu-action`, the dropped files `get-dropped-paths`, the task runner `add-task` and `cancel-tasks` once it is running and the test hooks `test-result` and `test-ui-ready` in a test hooks build only. The core holds this registry untyped and no public declaration of the core names it or `system-messages.zig`, so an app cannot reach it, register a system message or call a system handler. The registry's `register(name, handler)` is general enough for a plugin to call later.
- **One handler mechanism for both kinds.** `handlers.zig` wraps every handler, app or system, in the one function the core calls. The wrapper parses the message's data into the handler's request type, refusing data that does not fit with `InvalidMessageData` without running the handler. It turns what the handler returns (a response, `void`, a `ziggy.core.Answer` of `.now`, `.task` or `.later`, or a `ziggy.core.MessageResult` from a handler that takes the message unparsed) into the message response. A handler that answers `.later` takes a `ziggy.core.Reply`. The core records each such message until it is answered. It reports any that never is as a `core-error` system event naming `MessageNotAnswered` when it is destroyed. The [Messages](../user-guide/messages.md#what-a-handler-returns) guide lists the forms.

## The backend library

An app's backend library is built by `addAppBackend` in Ziggy's `build.zig`. Its root is Ziggy's `packages/ziggy/core/src/app-root.zig`, not a file of the app's: `createAppBackendModule` imports the app's `backend_source_file` (its `app.zig`) into it as `app-backend`. `app-root.zig` exports Ziggy's C interface (`ziggy-api.zig`) for that file's `pub const app` and, for an Android target, the JNI entry points (`jni.zig`). The app writes no exports and has no file of its own that the build starts from. A backend source file with no `app` declaration fails the build with a message that says so.

## Protocol

The system messages, each handled by Ziggy's core library and never by the app:

| Message | From | What it does |
|---|---|---|
| `get-platform` | `window.ziggy.getPlatform()` | Answers with `platformKind` (`desktop` or `mobile`), `os` and `arch`. |
| `add-task` | `window.ziggy.addTask(task)` | Queues a task. |
| `cancel-tasks` | `window.ziggy.cancelTasks(source)` | Cancels the tasks of a source. |
| `get-dropped-paths` | `window.ziggy.getPathForFile`, when a drop happens | Answers with the paths of the files in the last drop. |
| `menu-action` | The native app | Passes on a menu action the native app does not do itself, which the backend sends the UI as a `menu-action` system event. |
| `test-result` | `window.ziggy.sendTestResult(requestId, result)` | The UI's result for a `test-command`. Test hooks builds only. |
| `test-ui-ready` | `window.ziggy.testUiReady()` | Says the UI is listening for test commands. Test hooks builds only. |

A system message with a name no part of Ziggy has registered gets the error `UnknownSystemMessage`.

The system events, each with its own listener on `window.ziggy`:

| Event | Listener | What it says |
|---|---|---|
| `task-message` | `onTaskMessage` | A task sent a message while it ran: `taskId`, `source` and `message`. |
| `task-completed` | `onTaskCompleted` | A task ended: `taskId` and `result`. |
| `menu-action` | `onMenuAction` | A menu item that is the app's own was chosen: `action`. |
| `core-error` | `onCoreError` | A message failed with no message response to carry the error: `error`. With no listener it is logged to the console. |
| `test-command` | `onTestCommand` | A command from the test control connection: `requestId` and `command`. Test hooks builds only. |

## Tasks

- Background tasks run on a pool of worker threads in the backend, so slow work never blocks the UI.
- The UI queues a task with `window.ziggy.addTask`, can cancel it with `cancelTasks` and hears back through `onTaskMessage` and `onTaskCompleted`.
- A keep-alive task keeps a mobile app running in the background until it ends.
- The [Tasks](../user-guide/tasks.md) guide says how to write, queue and cancel one.

![How the UI queues a task, follows its progress, can cancel it and is told when it ends](diagrams/task-queue.svg)

## Native calls

- A native call is how the backend has the native app do something only native code can do: show a file dialog, read the operating system's version, quit, run a menu action, keep a mobile app running or take a screenshot.
- An app can add native calls of its own, which its own native code handles.
- The [Native calls](../user-guide/native-calls.md) guide says how to use them.

## Menus

- The backend describes the desktop menu once as JSON. Each desktop native app reads that description and builds a native menu from it with the platform's own menu API. A mobile device has no menu.
- The native app does the standard actions itself (quit, reload, zoom, the editing commands and the developer tools) and passes any other to the backend as a `menu-action` message, which the backend sends the UI as a `menu-action` event. The UI hears it through `window.ziggy.onMenuAction`.
- [Building your app](../user-guide/building-your-app.md#the-menu-and-the-window-icon) says how to write one.

## Test hooks

- Test hooks let the smoke tests drive the running app from outside, through a control connection on the loopback address.
- They are compiled in only with the `test-hooks` build option, which release builds never use.
- A command the UI performs reaches it as a `test-command` event (`window.ziggy.onTestCommand`), and the UI answers with `window.ziggy.sendTestResult`. The UI says it is listening with `window.ziggy.testUiReady()`.
- [Testing your app](../user-guide/testing.md) lists the commands.
