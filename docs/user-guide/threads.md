# Threads

## TLDR

- **Rule:** threads share no state. Each has its own allocator, Io and data. Only copies of JSON text pass between them, through message queues.
- **The threads**
  - **The native app's UI thread**, in the native app's language: Zig on Linux and Windows, Swift on macOS and iOS, Java on Android. It also runs the Zig functions of the C interface of Ziggy's core library that the native app calls. It runs the system web view, passes the frontend's messages on (except on Android) and delivers the backend's messages.
  - **The JavaScript bridge thread** (Android only, Java plus a Zig JNI function): passes each message from the frontend to the main thread.
  - **The main thread** (Zig): runs handlers, menu functions, timers and the app's callbacks, one at a time. It owns the worker pool.
  - **Background task worker threads** (Zig): each runs one task at a time.
  - **The test control threads** (Zig): only in a test hooks build.
  - **The frontend** (JavaScript): runs in the system web view, on threads the web view manages.
- **What each thread may touch:** its own `ThreadAllocator` and `std.Io`. The main thread's state stays on the main thread. A task gets JSON in and sends JSON back. Services are passed as arguments, never stored.
- **The message queue:** many threads post, one thread takes. Text is copied in on post and out on take. A waiting thread sleeps until a message comes or its next timer is due. Each message has a `from` number and can name a queue for its reply.
- **From the frontend to the backend:** `ziggy_send_message` is the backend's entry point for messages from the frontend: a C function declared in `ziggy.h` and written in Zig in Ziggy's core library (`ziggy-api.zig`), which posts the message to the main thread's queue. A message reaches it in three hops:
  1. **The page posts to the web view bridge.** The web view bridge is a JavaScript object the system web view puts in the page the native app hosts. Its `postMessage` hands text to the native app. `window.ziggy.invoke` or `send` turns the call into JSON text (`ziggy-inject.js`) and calls `postMessage` on `webkit.messageHandlers.ziggy` (Linux, macOS, iOS), `chrome.webview` (Windows) or `ZiggyAndroid` (Android). Runs on the page's JavaScript thread, which the system web view manages.
  2. **The web view calls the native app's callback** for that web view bridge: `onScriptMessage` (Linux), the `WebMessageReceived` handler (Windows), `userContentController(_:didReceive:)` then `ZiggyBridge.post` (macOS, iOS), `UiBridge.postMessage` (Android). Runs on the UI thread, or on the JavaScript bridge thread on Android.
  3. **That callback calls `ziggy_send_message`**, which copies the text onto the main thread's queue and returns at once. On Android it calls the JNI function `ZiggyNative.sendMessage`, which runs the same `sendMessage` in `core.zig`. Runs on the same thread as hop 2.
  - The native app also calls `ziggy_send_message` itself, for a menu item it does not handle (`menu-action`).
- **From the main thread's queue to the handler**
  1. **Stored** in the main thread's `MessageQueue`, made by `ziggy_create`.
  2. **Taken** by the main thread's loop (`mainThread` in `core.zig`), which passes it to `handleFrontendMessage`.
  3. **Handled** according to the message's `kind` field, which says whether it is an app message or a system message: `app` goes to `runAppMessage` and the app's handler, `system` goes to `runSystemMessage` and Ziggy's function under `system-messages/`. Any other kind is refused as `InvalidMessage`.
- **From the backend to the frontend:** the main thread posts to the native app's queue and calls its wake function. The UI thread takes each message with `ziggy_take_native_message` and calls `window.__ziggyReceive`, which settles the `invoke` or calls the event listeners.
- **Native calls:** a task asks the main thread, which posts the call to the native app's queue with the task's worker queue attached as the reply address. The UI thread does the call and posts the result straight to that worker queue.
- **The main thread and the background task workers:** they talk only by the messages Ziggy defines in `worker-messages.zig`. An app does not add to them: its own data travels inside them, as a task's input, events and result. One pending list holds interactive tasks at the head and background tasks at the end. Child tasks go through the main thread. Cancelling is cooperative and there is no task timeout. Shutdown cancels the tasks, waits for them to end, then joins the threads.
- **Threads an app starts itself:** each makes its own allocator, Io and queue, keeps its own caches and needs a way to be woken when the app stops.

The threads a Ziggy app runs on, what each one may touch and how they talk to each other. See the [glossary](../glossary.md) for "the frontend", "the backend" and "the native app". See [Tasks](tasks.md) for how to write and queue a task.

The rule underneath everything here: threads share no state. Every thread owns its own allocator, its own `std.Io` and its own data. The only thing two threads both touch is a message queue. The only thing that crosses it is a copy of JSON text. This is why the app's own state needs no locks.

## The threads

| Thread | Language | Started by | Runs |
|---|---|---|---|
| The native app's UI thread | The native app's language: Zig on Linux and Windows, Swift on macOS and iOS, Java on Android. It also runs the Zig functions of the C interface of Ziggy's core library (and on Android its JNI entry points) that the native app calls. | The platform | The system web view and the native app. It passes the frontend's messages to the backend (on Android the JavaScript bridge thread does this) and delivers the backend's messages to the frontend. |
| The JavaScript bridge thread (Android only) | Java, plus the Zig JNI function `ZiggyNative.sendMessage` | The Android WebView | `window.ZiggyAndroid.postMessage`: it passes each message from the frontend to the main thread's queue. |
| The main thread | Zig | Ziggy's core library, when the native app creates the backend (`ziggy_create`) | Every message handler, menu function and timer, plus `on_create`, `on_destroy`, `on_task_end` and `on_task_event`, one at a time in the order their messages arrived. It owns the worker pool. |
| Background task worker threads | Zig | The worker pool, when a task needs a worker | One task at a time. |
| The test control threads | Zig | Ziggy, in a test hooks build in test mode only | The test control connection. |

The frontend runs in JavaScript inside the system web view, on threads the system web view manages. Ziggy starts no thread there.

The main thread is never the native app's UI thread, on any platform. The native app sets the size of the worker pool and the limit on child tasks in flight when it creates the backend.

## What each thread may touch

- Each thread makes its own allocator when it starts (`ziggy.utils.thread_allocator.ThreadAllocator`). It has no lock, because only that thread uses it. Memory is never freed on a thread other than the one that allocated it.
- Each thread makes its own `std.Io`. A call into a message queue is given the Io of the calling thread.
- The main thread's state can be a top-level `var` of the backend, read and changed only by the functions that run on the main thread.
- A task never sees the main thread's state. It gets what it needs as JSON input when it is queued. The main thread hears what the task sends back in `on_task_event` and `on_task_end`.
- System services (an Io, an allocator, the timers, the handler, menu and task services) are never stored in a struct. Each function that uses one takes it as an argument.

## The message queue

All communication between threads goes through `MessageQueue` (`ziggy.message_queue`, in `packages/ziggy/core/src/lib/message-queue.zig`), the only place in Ziggy's core library where a lock appears.

- Any number of threads post to a queue. One thread takes from it.
- A post copies the sender's text into memory only the queue uses. A take copies it out into the taking thread's own allocator. No allocation crosses a thread.
- A thread waiting on an empty queue sleeps until a post or a timeout. The main thread and each worker wait no longer than until their next timer is due, so timers run on the thread that owns them.
- Each message carries a `from` number, so the main thread can tell the frontend, Ziggy's core library itself, the test control connection and each worker apart.
- A message can name a queue its reply goes to, for a sender that is not a thread the reader knows by number.

## Between the native app and the backend

### From the frontend to the backend

`ziggy_send_message` is the backend's entry point for messages from the frontend. It is a C function declared in `ziggy.h` and written in Zig in Ziggy's core library (`ziggy-api.zig`), so the Linux, Windows, macOS and iOS native apps can call it from Zig or Swift. The Android native app reaches the same code through a JNI function instead. A message from the frontend reaches it in three hops:

1. **The page posts the text to the web view bridge.** A web view bridge is a JavaScript object the system web view puts in the page the native app hosts. Calling its `postMessage` hands text to the native app. The frontend calls `window.ziggy.invoke` or `send`. The script every native app injects (`ziggy-inject.js`) turns the call into JSON text and calls `postMessage` on the web view bridge (see the table below). This hop runs on the page's JavaScript thread, which the system web view manages, not the native app.
2. **The web view hands the text to the native app.** The system web view calls a callback the native app registered for that bridge. This hop runs on the UI thread, except on Android, where the WebView calls it on its JavaScript bridge thread.
3. **The native app's callback calls `ziggy_send_message`.** That function (`sendMessage` in `core.zig`) posts a copy of the text to the main thread's queue under the number of the frontend and returns at once. The calling thread never waits on a message handler. This hop runs on the same thread as hop 2.

| Platform | 1. The page posts to | 2. The web view calls | 3. Which calls | Thread of hops 2 and 3 |
|---|---|---|---|---|
| Linux | `window.webkit.messageHandlers.ziggy.postMessage` | `onScriptMessage` in `native/linux/src/lib/native-app.zig`, connected to `script-message-received::ziggy` | `ziggy_send_message` | The UI thread |
| Windows | `window.chrome.webview.postMessage` | The `WebMessageReceived` handler in `native/windows/src/lib/native-app.zig` | `ziggy_send_message` | The UI thread |
| macOS and iOS | `window.webkit.messageHandlers.ziggy.postMessage` | `userContentController(_:didReceive:)` in `ZiggyBridge.swift`, which calls `ZiggyBridge.post` | `ziggy_send_message` | The UI thread |
| Android | `window.ZiggyAndroid.postMessage` | `UiBridge.postMessage` in `ZiggyNativeApp.java` | The JNI function `ZiggyNative.sendMessage` (`core/src/lib/jni.zig`), which calls the same `sendMessage` in `core.zig` that `ziggy_send_message` does. It makes a `ThreadAllocator` for the call. | The web view's JavaScript bridge thread, not the UI thread |

The native app also calls `ziggy_send_message` itself, without the page, for a menu item it does not handle itself: it sends the `menu-action` system message.

#### Why each platform has a different web view bridge

Each system web view provides its own web view bridge. It is there only in a page a native app hosts:

- **WebKit** (WebKitGTK on Linux, WKWebView on macOS and iOS): the native app registers a handler by name (`webkit_user_content_manager_register_script_message_handler` on Linux, `WKUserContentController.add(_:name:)` on Apple platforms). WebKit then gives the page `window.webkit.messageHandlers.<name>.postMessage` and calls the native app back for each message. Ziggy registers the name `ziggy`.
- **WebView2** on Windows: the runtime gives every page it hosts `window.chrome.webview.postMessage` and raises a `WebMessageReceived` event in the native app for each message.
- **The Android WebView**: the native app exposes a Java object to the page with `addJavascriptInterface`, under a name it picks. Ziggy exposes `UiBridge` as `window.ZiggyAndroid`. Its `postMessage` method is marked `@JavascriptInterface`, so the WebView calls it on its JavaScript bridge thread.

`findNativePost` in `ziggy-inject.js` looks for each web view bridge in turn, so the frontend's code is the same on every platform.

The name `postMessage` comes from the system web views, not from Ziggy. It is the HTML standard's name for sending a message (`window.postMessage`, `Worker.postMessage`). WebKit and WebView2 use it for their web view bridges. Ziggy cannot change those. The one `postMessage` Ziggy names itself is `UiBridge.postMessage` on Android, which takes the system web views' name so that `findNativePost` treats every web view bridge the same way. The frontend never calls `postMessage`: it calls `window.ziggy.invoke` and `send`, which are Ziggy's own API. The injected script calls the web view bridge's `postMessage` for them.

#### From the main thread's queue to the handler

1. The message is stored in the main thread's `MessageQueue`, in memory only the queue uses, until the main thread takes it. The queue is made by `ziggy_create`: a variable of `ziggy-api.zig` on Linux, Windows, macOS and iOS. On Android it is part of the JNI bridge.
2. The main thread's loop (`mainThread` in `core.zig`) takes the next message, copying it into its own allocator. It passes a message from the frontend to `handleFrontendMessage`. While the backend stops, a message from the frontend is dropped.
3. `handleFrontendMessage` reads the message's `kind` field, which says whether it is an app message or a system message (see the [glossary](../glossary.md)):
   - `app`: `runAppMessage` finds the app's handler for the message's name in the app declaration and calls it through its wrapper in `handlers.zig`, which parses the data and turns what the handler returns into the message response.
   - `system`: `runSystemMessage` finds Ziggy's own function for the name in its file under `system-messages/`, such as `add-task` and `cancel-tasks` in `system-messages/tasks.zig`.
   - Anything else is refused as `InvalidMessage`.

### From the backend to the frontend

1. The main thread posts the message response or event to the native app's queue and calls the native app's wake function (`native-app.zig`).
2. The wake function schedules the UI thread (`g_idle_add` on Linux, `DispatchQueue.main` on macOS and iOS). The UI thread then calls `ziggy_take_native_message` (its JNI counterpart in `jni.zig` on Android) until the queue is empty.
3. For each message the UI thread calls `window.__ziggyReceive` in the system web view. The injected script settles the `invoke` the response belongs to, or calls the frontend's event listeners.

### Native calls

- A task that needs the native app to do something (a file dialog, the phone's keychain) sends the main thread a `native-app-request`. The main thread posts the call to the native app's queue, with a pointer to the worker's own queue and a call id attached so the result knows where to go (`NativeApp.call` in `native-app.zig`). The UI thread does the call, then posts the result as a `native-app-response` straight to that worker's queue, where the task is waiting for it. See [Native calls](native-calls.md).

## Between the main thread and the background task workers

The worker pool (`worker-pool.zig`) lives on the main thread. Each worker (`worker.zig`) has a queue of its own. Every worker posts to the main thread's queue.

These are Ziggy's own messages, defined in `worker-messages.zig`. An app does not add to them: its own data travels inside them, as a task's input, the events it sends and its result. A Ziggy developer changes the list by changing that file and both sides that read it (`worker-pool.zig` and `worker.zig`).

| From the main thread to a worker | From a worker to the main thread |
|---|---|
| `execute`: run a task | `worker-ready` |
| `cancel-tasks`: the tasks of a source are cancelled | `task-message`: an event the task sent |
| `task-completed`: a child task the worker's task queued has ended | `queue-task`: queue a child task |
| `native-app-response`: the result of a native call | `native-app-request`: have the native app do something |
| `shutdown` | `task-completed`, `log`, `console` and `worker-error` |

- The pool keeps one list of pending tasks. An interactive task joins the head and a background task joins the end. An idle worker takes from the head.
- A child task goes to the main thread, which queues it in the same pool. Its end is sent back to the worker whose task queued it, which reads it while the task waits.
- Cancelling is cooperative. A thread cannot be stopped from outside it, so `cancel-tasks` sets a flag the task reads through `isCancelled()` or `checkCancelled()`. A pending task of the source is dropped without running.
- The pool has no task timeout, because a thread cannot be ended from outside it. See [Child tasks](tasks.md#child-tasks) for what that means for a parent that waits on its children.
- When the backend stops, the main thread drops the pending tasks, cancels the running ones and reads its queue until each has ended. Then it sends every worker `shutdown` and waits for its thread to end.

## Threads of the app's own

An app can start threads of its own, such as the threads of a server it runs. Keep to the same rule:

- Each thread makes its own `ThreadAllocator` and its own `std.Io` when it starts.
- Each thread that is sent messages has a `MessageQueue` of its own. Its owner sends it everything it needs as JSON text. It sends its results back the same way.
- A thread keeps its own copy of anything it caches. Two threads never read or write the same memory.
- A thread that can wait a long time (on a socket, on a queue) needs a way to be woken when the app stops, such as a `stop` message on its queue, so `on_destroy` can end it.

## Key files

| File | What it holds |
|---|---|
| `packages/ziggy/core/src/lib/core.zig` | The main thread and its message loop. |
| `packages/ziggy/core/src/lib/message-queue.zig` | The queue every thread reads its messages from. |
| `packages/ziggy/utils/src/lib/thread-allocator.zig` | The allocator each thread makes for itself. |
| `packages/ziggy/core/src/lib/native-app.zig` | How a thread of the backend reaches the native app. |
| `packages/ziggy/core/src/lib/worker-pool.zig` | The main thread's side of the tasks. |
| `packages/ziggy/core/src/lib/worker.zig` | A worker thread and how it runs a task, waits and is cancelled. |
| `packages/ziggy/core/src/lib/worker-messages.zig` | The messages between the main thread and the background task workers. |

## To fix

- Investigate why `ThreadAllocator` is needed for threads (it's based on DebugAllocator, Why would we use that in prod code?) and remove it if not required.
- Rename `ziggy_send_message` to `ziggy_receive_message`.
- Rename `runXXX` to `handleXXX`.
- Fix the names `ziggy_take_native_message` and `window.__ziggyReceive`.
