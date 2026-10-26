# The app declaration

Terms are defined in the [glossary](../glossary.md).

The app declaration is where an app gives Ziggy its messages, its task types, its menu, its built frontend and the functions Ziggy calls as the backend runs and ends.

## Declaring the app

An app declares itself to Ziggy in one file, `backend/src/app.zig` in the template, with `ziggy.core.App`. It lists every message with its handler, every task type with its task handler and what else the app gives Ziggy. This is the template's:

```zig
const ziggy = @import("ziggy");
const hello_world = @import("lib/hello-world.zig");
const menu = @import("lib/menu.zig");
const ui_query = @import("lib/ui-query.zig");
const ui = @import("ui-files");

pub const app = ziggy.core.App(.{
    // Each message name the frontend sends, with the function that handles it.
    .messages = .{
        .@"hello-world" = hello_world.helloWorldHandler,
    },

    // Each task type the frontend queues, with the function that runs it.
    .tasks = .{
        .@"hello-world-task" = hello_world.helloWorldTaskHandler,
    },
    .menu = menu.menu,
    .ui_files = &ui.files,
    .ui_query = ui_query.uiQuery,
});
```

The fields of `ziggy.core.App`:

| Field | Required | What it is for |
|---|---|---|
| `messages` | Yes | Each field is a message name and its handler, in any of the forms under [What a handler returns](messages.md#what-a-handler-returns). `.{}` for an app with none. See [Messages](messages.md). |
| `tasks` | Yes | Each field is a task type and its task handler, or `.{ .handler = ..., .kind = .keep_alive }` for a keep-alive task type. See [Tasks](tasks.md#registering-a-handler). |
| `menu` | Yes | The desktop menu, a `[]const ziggy.menu.Menu`, `&.{}` for none. It is checked when the app is built. See [Menus](menus.md). |
| `ui_files` | Yes | The files of the app's built frontend, `&ui.files` from the `ui-files` module the build makes. |
| `ui_query` | No | A function that gives the query the native app adds to the frontend's address, so the frontend's first render already holds what the backend tells it at start-up. |
| `describe_error` | No | A function that turns an error a handler returned into the text of the error response (see [When a handler fails](messages.md#when-a-handler-fails)). |
| `on_task_end`, `on_task_event` | No | Functions told of every task that ends and every event a task sends. |
| `on_create` | No | A function called once when the backend is created, before any message or task reaches the app, so the app can make what its handlers and tasks need. See [When the backend is created](#when-the-backend-is-created). |
| `on_destroy` | No | A function called twice when the backend is destroyed, so the app can stop its own threads and then free its own resources. See [When the backend is destroyed](#when-the-backend-is-destroyed). |

`ziggy.core.App` checks every field and every handler when the app is built. A field it does not know, a required field that is missing or a handler of the wrong type fails the build with a message that names it.

Apart from this declaration, the app developer writes no code to connect the backend to Ziggy: no exported functions, no JNI entry points and no `main`. The app's `build.zig` names this file as `backend_source_file` in `addAppBackend`. Ziggy's build makes the backend library from it: the library exports Ziggy's C interface for the app's `app` and, for Android, the JNI entry points of Ziggy's Android native app. The app also gives its details (name, title and version) in an `app.zon` beside its `build.zig` (see [The app's details](building-your-app.md#the-apps-details)).

## What every handler is given

Every message handler, menu item function and app function above (`ui_query`, `on_task_end`, `on_task_event`, `on_create` and `on_destroy`) runs on the backend's main thread and takes the same standard arguments first, whether it uses them or not:

| Argument | Type | What it is |
|---|---|---|
| `services` | `ziggy.core.HandlerServices` | What the handler reaches the main thread through (see below). |
| `timers` | `ziggy.timers.Timers` | The main thread's timers: `setTimeout`, `clearTimeout`, `setInterval` and `clearInterval`, as JavaScript has them. A callback runs on the main thread. |
| `io` | `std.Io` | The main thread's Io, for sleeping, files and sockets. |
| `allocator` | `std.mem.Allocator` | Memory for the call. Ziggy makes no promise about when it is freed, so anything kept after the call is allocated with an allocator of the app's own. |

A task handler takes the same, with `ziggy.task_runner.TaskServices` for its services and its worker's timers and Io, and then its context (see [Tasks](tasks.md#writing-a-handler)).

The handler services are an interface, as `std.Io` is: the handler does not see how the main thread keeps its state. Each call runs on the main thread and is done before it returns. The services may be kept, for a timer's callback for one, until the main thread has called `on_destroy` for the last time.

| Function | What it does |
|---|---|
| `sendEvent(allocator, data_json)` | Sends the frontend an app event whose data is the JSON text, which the frontend's `onEvent` listeners receive. |
| `addTask(task_id, task_type, source, data_json, priority)` | Queues a task of the type, with the id, the source it is cancelled by and the JSON text of its input. |
| `cancelTasks(source)` | Cancels every task queued under the source. |
| `holdKeepAlive(keep_running)` | Keeps the app running with or without a task, through the native app's `keep_alive` callback, until it is called with `false`. |
| `quit()` | Has the native app quit. A native app with no `quit` callback ignores it. |
| `menuAction(action)` | Has the native app run one of its own menu actions, such as `focus-window`. A native app with no `menu_action` callback ignores it. |
| `dataDir()` | The app's private data directory. |
| `isPhone()` | Whether the native app is a phone's: the Android and iOS native apps handle the app's own native calls, which no desktop native app does. |

## When the backend is created

An app that has to make something before its handlers and tasks run (its own state, task handlers it registers with the task queue) gives `on_create` a function. Ziggy calls it once, on the backend's main thread, when the backend is otherwise ready: tasks can be queued, but no message or task has reached the app yet. If it returns an error, creating the backend fails with that error, Ziggy releases what it made and the native app reports the error. `on_destroy` is not called then, so `on_create` must release what it made itself before it returns the error. Ziggy keeps nothing for the app, so the app keeps what it makes where its handlers can reach it.

```zig
//
// Opens the app's cache before any handler can use it.
//
fn onCreate(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!void {
    _ = timers;
    _ = allocator;
    try cache.init(std.heap.smp_allocator, io, services.dataDir());
}

pub const app = ziggy.core.App(.{
    // ...
    .on_create = onCreate,
});
```

Here `cache` stands for the app's own code.

## When the backend is destroyed

An app that starts threads of its own or allocates things that outlive a message gives `on_destroy` a function. Ziggy calls it twice, on the backend's main thread, while the backend is destroyed:

- `.before_tasks_stop`, first: tasks can still be queued and the ones running are still running. Stop the app's own threads here, since they may still queue tasks.
- `.after_tasks_stopped`, once every task has ended: no task runs and none can be queued. Free what the app's own code allocated here.

The backend is destroyed whenever the native app ends it, which is not only when the app quits: on Android it ends with the activity, which Android can destroy while the app's process lives on and later create again, and tests create and destroy it many times. So `on_destroy` must leave nothing behind that the next backend would trip over.

```zig
//
// Stops the app's threads before tasks stop and frees its cache once they have.
//
fn onDestroy(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, phase: ziggy.core.DestroyPhase) void {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    switch (phase) {
        // Tasks still run, and the watcher may still queue them.
        .before_tasks_stop => watcher.stop(),
        // No task runs now and none can be queued, so the cache can go.
        .after_tasks_stopped => cache.deinit(std.heap.smp_allocator),
    }
}

pub const app = ziggy.core.App(.{
    // ...
    .on_destroy = onDestroy,
});
```

Here `watcher` and `cache` stand for the app's own code.

## See also

- [Messages](messages.md): the messages listed in `.messages`.
- [Tasks](tasks.md): the task types listed in `.tasks`.
- [Menus](menus.md): the menu given in `.menu`.
