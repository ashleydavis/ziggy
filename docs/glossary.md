# Glossary

- **Ziggy**: this framework for building cross-platform apps.
- **App developer**: the person building an app on Ziggy.
- **The app**: everything the app developer builds and ships with Ziggy: the UI, the backend and the native app together.
- **The UI**: the app's HTML, CSS and JavaScript/TypeScript, which runs in the system web view. The native menus and file dialogs are not part of it.
- **The backend**: the app's own Zig code, which does the app's work behind the UI: it handles the UI's messages and runs tasks. It is the same code on every platform and never touches a window.
- **Ziggy's core library**: the part of Ziggy every backend is built on: the routing of messages to handlers, the task runner and the C interface the native app calls.
- **The native app**: the part of the app that is different on each platform. Ziggy provides it and the app developer customizes it. It opens the window, hosts the system web view, draws the menus and file dialogs and passes messages, message responses and events between the UI and the backend.
- **The system web view**: the browser engine each platform provides for showing web content: WebKitGTK on Linux, WebView2 on Windows, the Android WebView and WKWebView on macOS and iOS. This is where Ziggy apps render their UI.
- **Message**: a JSON object the UI sends to the backend on a channel. It is passed inside the app, through the native app, and is not an HTTP request.
- **Message response**: the JSON object the backend sends back to the UI for a message, or the error the message ended with.
- **Channel**: the name of a kind of message or event, such as `add-task`. Ziggy's core library routes each message to the handler registered for its channel.
- **Event**: a JSON object the backend sends to the UI on a channel when something happens, such as a task finishing (`task-completed`).
- **Handler**: the Zig function that runs for a channel or a task type.
- **Task**: work that runs on a worker thread and reports back to the UI by events. Its **task type** is the name its handler is registered under.
- **Task context**: what a running task is given to work with: the means to report back, to check whether it should stop and to queue child tasks and wait for them.
- **Task queue**: where queued tasks wait until a worker thread is free to run them. It is part of Ziggy's core library.
- **Native call**: a call from the backend to the native app, for something only the native app can do, such as showing a file dialog. The backend waits for it to return. Ziggy has its own, and an app can add its own.
- **OS call**: a call from the native app or the backend straight to the operating system, such as reading a file or opening a window.
