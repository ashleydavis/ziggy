# Tasks

A task is work the backend runs on its own pool of worker threads, away from the thread that handles the frontend's messages. Anything slow (reading files, hashing, talking to the network, waiting on the user in a native dialog) is a task. A task can report progress while it runs, queue child tasks and be cancelled. See the [glossary](../glossary.md) for "the frontend", "the backend" and "the native app".

## How it works

```mermaid
sequenceDiagram
    participant UI as Frontend
    participant NativeApp as Native app
    participant Backend as Backend (core library)
    participant Runner as Task runner
    participant Worker as Worker thread

    UI->>NativeApp: window.ziggy.addTask({ taskId, taskType, source, data, priority })
    NativeApp->>Backend: the add-task system message
    Backend->>Runner: addTask
    Note over Runner: The task waits in the queue.<br/>Interactive tasks go to the head,<br/>background tasks to the end.
    Runner->>Worker: runs the handler when a thread is free
    loop While the handler runs
        Worker-->>NativeApp: services.sendEvent(...)
        NativeApp-->>UI: task-event system event { taskId, source, data }
    end
    Worker->>Runner: the handler returns its result or an error
    Runner-->>NativeApp: the completion
    NativeApp-->>UI: task-completed system event { taskId, result }
```

- The frontend makes up the task's id and names a source. The source groups tasks so they can be cancelled together.
- There is one queue. An interactive task goes at the head of it and a background task at the end. A task with no priority runs as background.
- The native app sets the number of worker threads and the limit on child tasks in flight when it creates the backend (`ziggy_create`).
- A task that is cancelled ends as failed, with the error message `Cancelled`.

The `/ziggy:add-task` Claude Code command adds a task type to an app by following this guide.

## Writing a handler

A handler is a Zig function that takes the standard arguments of a task handler: the task services, its worker's timers, its worker's Io, an allocator, the task's context and the data the frontend queued it with, parsed into a payload type of the handler's own as a message's data is (see [Messages](messages.md#a-message-handler)), or `std.json.Value` for the data unparsed. It returns its result, which Ziggy turns into JSON, or `void` for none. Returning an error fails the task. The error message is the error's name, unless the app sets `describe_error` to a function that describes it.

```zig
const std = @import("std");
const ziggy = @import("ziggy");

const TaskServices = ziggy.task_runner.TaskServices;
const TaskContext = ziggy.task_runner.TaskContext;
const Timers = ziggy.timers.Timers;

//
// The hello-world task: sends the frontend one output event while it runs, then completes with a result.
//
pub fn helloWorldTaskHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) ![]const u8 {
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = payload;

    // Sends the frontend an event while the task runs, which the frontend hears through window.ziggy.onTaskEvent.
    try services.sendEvent(.{
        .type = "output",
        .text = "Hello world from a task",
    });

    // Completes the task with its result, which Ziggy turns into JSON.
    return "hello world task done";
}
```

Allocate what the result holds with `allocator`. Ziggy makes no promise about when it is freed, and it lasts at least until the task's result has been sent.

The task's context holds plain values the task is started with:

| Field | What it is |
|---|---|
| `task_id` | The task's id. |
| `task_type` | Its task type, for a handler that serves several. |
| `source` | The source it was queued under. |
| `max_concurrent_child_tasks` | The limit on this task's child tasks in flight. |
| `data_dir` | The app's private data directory. |

The task services are what the task reaches outside its worker through. Each call is a JSON message to the main thread, which the task does not see:

| Function | What it does |
|---|---|
| `sendEvent(value)` | Sends any value `std.json` can serialise to the frontend as a `task-event` system event. |
| `isCancelled()` | Whether the task's source has been cancelled. |
| `checkCancelled()` | Returns `error.Cancelled` when the source has been cancelled. Call it at the top of every loop. |
| `queueChild(type, data, priority)` | Queues a child task and returns its id. It waits while the child limit is reached. |
| `awaitTask(child_id)` | Waits for one child and returns how it ended. A failed child is returned as a failure. |
| `runChild(allocator, type, data, priority)` | Runs one child to its end and frees it, for a task that runs children one after another for as long as it lives. |
| `nativeCall(method, request_json)` | Calls the native app's `native_call` native call to do one thing only the platform can do, by name, and returns its result. A platform with no `native_call` native call gives `error.NativeCallMissing`. |
| `nativeCaller(storage)` | Hands this task's native calls to code that does not know about tasks, or null when the native app has no `native_call` native call. |
| `pickPaths(kind, title, initial_name)` | Shows a native file or directory dialog and returns the JSON text of the paths chosen, an empty array when the user cancelled. In a test hooks build a test can supply the paths instead. |
| `osVersion()` | The operating system's version, through the native app's `os_version` native call. |

The timers are the worker's own: a timer the task sets runs on its worker while the task waits for a message, and is cleared when the task ends.

## Registering a handler

The app lists its task types in the `.tasks` field of its `ziggy.core.App` (see [The app declaration](app-declaration.md)), in `backend/src/app.zig` in the template. Each field is a task type and its handler:

```zig
.tasks = .{
    .@"hello-world-task" = hello_world.helloWorldTaskHandler,
},
```

- The field's name is the task type the frontend queues it under.
- A task type is `.normal` unless it is given as `.{ .handler = ..., .kind = .keep_alive }`. A keep-alive task keeps the app running on a mobile device while it is in the background (see "Keep-alive tasks" below).
- A task type that nothing is registered for fails as `UnknownTaskType`, in a failed `task-completed` event.

The task types in `.tasks` are the only ones the backend runs: every worker is given the list when it starts.

## Queuing a task from the frontend

```typescript
window.ziggy.addTask({
    taskId: "my-task-1",
    taskType: "hello-short",
    source: "my-source",
    data: {},
    priority: "background",
});
```

- `taskId`: the id the frontend makes up for the task. The task's events carry it, so the frontend can tell which task they belong to.
- `taskType`: the name the handler was registered under.
- `source`: the group the task belongs to, for cancelling.
- `data`: any JSON. It is parsed into the handler's `payload`.
- `priority`: `"interactive"` for something the user is waiting on, `"background"` for everything else. Leave it out for background.

## Receiving the events

```typescript
window.ziggy.onTaskEvent(event => {
    // event.taskId, event.source, and event.data (what the handler sent)
});

window.ziggy.onTaskCompleted(event => {
    // event.taskId, and event.result:
    //   status: "succeeded" or "failed"
    //   errorMessage: why it failed ("Cancelled" for a cancelled task)
    //   outputs: what the handler returned
    //   type: the task type
    //   inputs: the data the task was queued with
});
```

Every event a handler sends arrives as one `task-event` event. The template gives each event a `type` field (`"output"`, `"job-progress"`) and the frontend decides what to do with it from that. Ziggy does not look inside an event. `removeTaskEventListener(callback)` and `removeTaskCompletedListener(callback)` stop a callback hearing them.

## Cancelling

```typescript
window.ziggy.cancelTasks("my-source");
```

Cancelling a source cancels its queued and running tasks, children included. A running task stops only when its handler next calls `checkCancelled()` or `isCancelled()`, so a handler that loops must check at every step.

## Child tasks

A handler can split its work into child tasks with `queueChild` and wait for each with `awaitTask`. Ziggy's test app does this in `hello-long`, in `apps/ziggy-test-app/backend/src/lib/handlers.zig`. Ziggy waits for every child a task still has before the task ends.

- Children run on the same pool as their parent. A parent that waits on its children keeps its worker thread while it waits, as in TypeScript, so if every worker holds a waiting parent the queue stops: no worker is free for the children they wait on. TypeScript frees a worker when its task runs past the pool's task timeout, by failing the task and ending the worker. Ziggy cannot end a thread from outside it, so it has no task timeout, and the queue stays stopped until those parents are cancelled or the app stops. This is not a problem in practice, and it may have to be addressed later.
- A child runs at the priority passed to `queueChild` or `runChild`, and otherwise at its parent's.
- A failed child makes `awaitTask` return its failure to the parent.


## A message whose response is a task's result

A message the frontend sends with `window.ziggy.invoke` is handled by its message handler on the thread that handles the frontend's messages, so it must be quick. When the message response takes time, the handler has a task give it instead: it returns a `ziggy.core.Response(Result)` holding `.task`, with the task type and the task's input as JSON text. Ziggy queues a task of that type. The task's result is the message response. A task that fails or is cancelled gives an error message response. Ziggy's test app handles its file and directory pickers this way, because they wait on a native dialog, in `apps/ziggy-test-app/backend/src/lib/handlers.zig`:

```zig
pub fn pickFolderMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: PickFolderRequest) !ziggy.core.Response(?[]const u8) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "pick-folder",
            .data = try json.stringify(allocator, payload),
        },
    };
}
```

- The handler decides what the task's input is: here the whole of the payload.
- These tasks run under the source `"request"`, so `cancelTasks("request")` cancels every one still running.
- A message sent with `send` has no id and so no response: it fails with `MessageHasNoId` and nothing is queued.
- The task is not one the frontend queued, so it sends no `task-completed` event of its own: its result reaches the frontend only as the message response.
- A handler that takes the message unparsed (see [Messages](messages.md#taking-the-message-unparsed)) does the same by returning a `MessageResult` holding `.task`.

## Threads and state

Message handlers, menu functions and timers run on the backend's main thread, a thread Ziggy starts that is not the native app's UI thread, on every platform. Tasks run on worker threads. Each thread keeps its own state and never touches anything that belongs to another thread, so the app's own state needs no locks.

- The main thread's state can be a variable at the top level of the backend, read and changed only by message handlers and menu functions.
- A task's state lives in the task: its handler's local variables and what it allocates with its allocator.
- Only the handlers and task handlers Ziggy calls keep state. The functions they call keep nothing of their own and take what they need as arguments.
- Threads talk only by JSON messages. The frontend sends messages to the main thread. A task gets its input as JSON data when it is queued (`data` in `window.ziggy.addTask`, or `.data` of a `.task` result), reports with `services.sendEvent` and ends with its result, all JSON.
- `on_task_end` and `on_task_event` (see [The app declaration](app-declaration.md)) run on the main thread, when it hears from the worker that the task ended or sent an event.
- In dev mode the dev backend's core keeps the same main thread for as long as it runs, and a page reload does not change it. Keep the main thread's state in an ordinary top-level `var`.

It works like an Electron app: the main thread is like the main process, and each task is like a worker that shares nothing with it and talks to it only by messages.

Here a message handler keeps a count on the main thread and has a task give its response. The task never reads `greeting_count`: it gets the count in its JSON input and sends its greeting back as its result, which reaches the frontend as the message response.

```zig
// The main thread's state: how many greetings have been requested. Only message handlers read or change it.
var greeting_count: u32 = 0;

pub fn greetMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: GreetRequest) !ziggy.core.Response([]const u8) {
    _ = services;
    _ = timers;
    _ = io;
    greeting_count += 1;
    return .{
        .task = .{
            .task_type = "write-greeting",
            .data = try ziggy.json.stringify(allocator, .{
                .name = payload.name,
                .count = greeting_count,
            }),
        },
    };
}
```


## Keep-alive tasks

A task type registered with `kind = .keep_alive` keeps a mobile app running in the background while any task of that type is queued or running. Its children are covered by it. The frontend queues it like any other task.

- **Android:** a foreground service runs with an ongoing notification, whose wording the app sets with `ZiggyNativeApp.setKeepAliveNotification`. Finishing the activity still ends the app's tasks.
- **iOS:** the app holds a background task assertion, which the system ends after a limited time and then suspends the app.
- **Linux, Windows and macOS:** nothing changes. Closing the window quits the app.

## Code written against the task queue

The core library implements the task queue's `IQueueBackend` on each worker, which sends the child tasks a task queues to the main thread, and on the main thread's worker pool, so code written against `TaskQueue` and `IQueueBackend` (`@import("ziggy").task_queue`) runs on it unchanged. Each thread has its own backend.

- A handler written against the task queue (that package's `TaskHandler`) is listed in `.tasks` like any other.
- A task queued through a worker's backend runs at the priority of the task that queued it, unless the code passes one.
- `onTaskComplete` callbacks hear of every task that ran, a cancelled one as failed with the message `Cancelled`. A task cancelled while it waited in the queue is not reported to them, though the frontend is told.


## Key files

| File | What it holds |
|---|---|
| `packages/ziggy/core/src/lib/task-runner.zig` | `TaskServices`, `TaskContext`, `TaskHandlerEntry`, `TaskPriority` and `TaskKind`. |
| `packages/ziggy/core/src/lib/worker-pool.zig` | The worker pool, which owns the tasks on the main thread. |
| `packages/ziggy/core/src/lib/worker.zig` | A worker, which runs one task at a time. |
| `packages/ziggy/core/src/lib/system-messages/tasks.zig` | Ziggy's own `add-task` and `cancel-tasks` system messages. |
| `packages/ziggy/core/src/lib/core.zig` | The main thread, which queues the task whose result is a message's response. |
| `packages/ziggy/core/src/lib/handlers.zig` | `Response`, whose `.task` makes a task's result a message's response. |
| `packages/ziggy/core/src/lib/task-queue` | The task queue that Ziggy's core library implements its queue backend for. |
| `apps/ziggy-template/backend/src/lib/hello-world.zig` | The template's hello world task. |
| `apps/ziggy-test-app/backend/src/lib/handlers.zig` | Everything the test app registers, including its task handlers: long tasks, child tasks, cancelling, failing and keep-alive. |
| `apps/ziggy-template/frontend/src/main.ts` | How the template's frontend queues tasks and handles their events. |


## See also

- [Claude Code commands](claude-code-commands.md): `/ziggy:add-task` and the other slash commands.
- [Ziggy architecture](../development/architecture.md#tasks): where tasks fit in an app.
