# Messages

Terms are defined in the [glossary](../glossary.md).

A message is how the frontend asks the backend for something. The frontend sends a message with a name and any JSON data, the backend runs the Zig function registered for that name (the message's handler) and sends back a message response. The backend can also send the frontend an event when something happens. All of it passes inside the app, through the native app: there is no HTTP and no network.

This guide is about app messages and app events, the app's own. Every app message has a message name, a string that names what the message is for, such as `hello-world`. The app registers one handler for each name. Ziggy parses the message's data into the type the handler takes and turns what the handler returns into the message response.

The `/ziggy:add-message` Claude Code command adds a message to an app by following this guide.

## Registering message handlers

The app registers a handler for each of its messages in the `.messages` field of its [app declaration](app-declaration.md), `ziggy.core.App` in `backend/src/app.zig` in the template. Each field is a message name and its handler, in any of the forms under "What a handler returns" below. This is the template's:

```zig
pub const app = ziggy.core.App(.{
    // Each message name the frontend sends, with the function that handles it.
    .messages = .{
        .@"hello-world" = hello_world.helloWorldHandler,
    },
    // ...
});
```

## A message handler

A message handler takes the backend, an arena and the message's data parsed into a type of the handler's own and returns the message response. This is the template's, in `backend/src/lib/hello-world.zig`:

```zig
//
// The data of the frontend's hello-world message.
//
pub const HelloWorldRequest = struct {
    // Who to greet.
    name: []const u8,
};

//
// The message response to the hello-world message.
//
pub const HelloWorldResponse = struct {
    // The greeting, naming the platform the app runs on.
    greeting: []const u8,
};

//
// Handles the frontend's hello-world message: returns a greeting for the name in the message's data, naming the platform the app runs on.
//
pub fn helloWorldHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: HelloWorldRequest) !HelloWorldResponse {
    _ = core;

    // Ziggy turns the response into JSON and sends it back to the frontend. The greeting is allocated from the arena, which is freed once
    // the response has been sent.
    return .{
        .greeting = try std.fmt.allocPrint(arena, "Hello {s}, from Zig on {s}", .{
            request.name,
            @tagName(builtin.os.tag),
        }),
    };
}
```

- Before the handler runs, Ziggy parses the message's data into the type of its third parameter with `std.json`. The request can be a struct or any other type `std.json` can parse into, such as `[]const u8` for a bare string.
- Fields of the data that the request type does not have are ignored. Data that is null is parsed as an empty object when the request is a struct, so a request with no fields, or with every field optional or given a default, needs no data.
- Data that does not fit is refused with `InvalidMessageData` and the handler does not run (see "When a handler fails" below).
- What the handler returns is turned into the JSON of the message response.
- Define the request and response types beside the handler, so the handler is where its payload is described.

Allocate from `arena`. It is freed once the handler has returned and the message response has been sent.

The handler runs on the native app's main thread on every platform, the thread that handles every message from the frontend, in the order the messages arrived (in dev mode, the dev backend handles them on the thread serving the page's connection). It must be quick, because the window waits while it runs. Anything slow, such as reading many files, hashing or waiting on the network, is a task instead. A task never touches the state the main thread keeps: see [Threads and state](tasks.md#threads-and-state).

## What a handler returns

A handler is one of these forms, where `Request` is the type the data is parsed into and `Response` the type of the response:

```zig
fn (core: *ziggy.core.Core, arena: std.mem.Allocator, request: Request) !Response
fn (core: *ziggy.core.Core, arena: std.mem.Allocator, request: Request) !ziggy.core.Answer(Response)
fn (core: *ziggy.core.Core, arena: std.mem.Allocator, request: Request, reply: ziggy.core.Reply(Response)) !ziggy.core.Answer(Response)
fn (core: *ziggy.core.Core, arena: std.mem.Allocator, message: ziggy.core.Message) !ziggy.core.MessageResult
```

What it returns decides the message response:

- A `Response`: sent at once as the message response.
- `void`: there is nothing to send back. A message with an id still gets a successful message response holding null, so the frontend's `invoke` never waits for ever.
- A `ziggy.core.Answer(Response)`, one of:
  - `.{ .now = value }`: the response, sent at once.
  - `.{ .task = .{ .task_type = "...", .data = json_text } }`: a task of that type is queued with `data` (JSON text, which `ziggy.json.stringify` makes from any value) as its input. The task's result is the message response. See "A message answered by a task" below.
  - `.later`: the message is answered afterwards through the handler's `reply` (see "Answering later" below). Only a handler that takes a `reply` may return it: any other handler that returns `.later` fails with `MessageNotAnswered`.
- A `ziggy.core.MessageResult`, from a handler that takes the message unparsed (see "Taking the message unparsed" below).

## Answering later

A handler that cannot answer before it returns, because the answer comes from something it starts and does not wait for, takes a fourth parameter, `reply: ziggy.core.Reply(Response)`, keeps it and returns `.later`. Here `startLookUp` stands for the app's own code, which keeps the reply and answers with it when the look-up ends:

```zig
pub fn lookUpHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: LookUpRequest, reply: ziggy.core.Reply(LookUpResponse)) !ziggy.core.Answer(LookUpResponse) {
    _ = arena;
    try startLookUp(core, request.key, reply);
    return .later;
}
```

- The reply is a small value that can be copied and stored anywhere. It answers the message once, from any thread, with `reply.send(value)` or with `reply.fail(err)`, which gives an error response as a handler's error does.
- Answering a second time is the error `MessageAlreadyAnswered`.
- A message whose reply is never answered is reported, when the backend shuts down, as a `core-error` system event naming `MessageNotAnswered` and the message's name. The reply must not be used after that.
- A handler that takes a reply may still return `.now` or `.task` and then must not use the reply. It returns an `Answer` of the same `Response` its `Reply` has, or the build fails.

## Taking the message unparsed

A handler can take the message as Ziggy received it, with `ziggy.core.Message` as its third parameter, and return a `ziggy.core.MessageResult`. Ziggy's test app answers its `ping` message this way, in `apps/ziggy-test-app/backend/src/lib/handlers.zig`, because it echoes data of any kind without parsing it.

- `message.name` is the message name the frontend sent.
- `message.data` is the data the frontend sent, as a `std.json.Value`, null when it sent none.
- `message.id` is the message's id, which the message response carries back to the frontend. It is null for a message sent with `send`.

What it returns:

- `.{ .response = json_text }`: the JSON text of the message response, allocated with the arena. It is sent when the message has an id.
- `.none`: as `void` above.
- `.answered_by_task`: what `core.answerWithTask(message, task_type, data_json)` returns, which queues a task whose result is the message response, as `.task` does.

## Registering a message later

The messages in `.messages` are registered when the backend starts. The app can register more at any point while the backend runs, from any thread, with `core.registerMessage(name, handler)`, which takes a handler function known when the app is built, in any of the forms above. The message is handled from then on.

- A name that is registered already, in `.messages` or by an earlier call, is the error `DuplicateMessage`. The name is printed.
- It only ever registers an app message. Ziggy's own system messages are kept apart and an app cannot register one.

```zig
try core.registerMessage("look-up", lookUpHandler);
```

## Sending a message from the frontend

The frontend sends a message with `window.ziggy.invoke(name, data)`, which resolves with the data of the message response. Both arguments are required: pass `null` as the data when there is none.

```ts
const response = await window.ziggy.invoke<IHelloWorldResponse>("hello-world", {
    name: "world",
});
```

`window.ziggy.send(name, data)` sends a message that gets no message response, and takes the same arguments. The types of `window.ziggy` come from the `ziggy` package.

## When a handler fails

A handler that fails returns a Zig error. `invoke` then rejects with an `Error` whose message is the error's name, such as `ExampleFailure`, because a Zig error carries no text of its own. A message sent with `send` that fails has no message response to carry the error, so it is reported as a `core-error` event (see "Ziggy's own calls" below).

Ziggy refuses these before any handler runs. They fail the same way as a handler error: `invoke` rejects, and a message sent with `send` gives a `core-error` event.

- `MissingMessageName`: the message's name is missing, empty or not a string.
- `UnknownMessageName`: no message is registered under the name.
- `InvalidMessageData`: the data does not fit the handler's request type. The error describes how: `InvalidMessageData: the data is not an object`, `InvalidMessageData: the field "name" is missing`, `InvalidMessageData: the field "name" does not fit (<error>)`, or for a request that is not a struct, `InvalidMessageData: <error>`, where `<error>` is the name of the error `std.json` gave.

An app that can describe a failure in more detail gives `ziggy.core.App` a `describe_error` function. The backend calls it with the error a message handler or a task's handler returned, or a reply was failed with. It uses the text it returns in place of the error's name. It returns null for an error it has no description of. This is the test app's:

```zig
pub fn describeError(err: anyerror) ?[]const u8 {
    if (err == error.Refused) {
        return "The test app refused, as it was asked to.";
    }
    return null;
}
```

## A message answered by a task

A message whose message response takes time is answered by a task, so it does not hold up the other messages: the handler returns `.{ .task = ... }`. The [Tasks](tasks.md#a-message-answered-by-a-task) guide explains how.

## Sending an event to the frontend

The backend sends an app event with `core.sendEvent(arena, data_json)`, where `data_json` is the JSON text of the event's data. Like a message, an event's data is the app's to lay out, and the template gives it a `type` field. Events have no message name. Here a handler tells the frontend it queued a task:

```zig
try core.sendEvent(arena, try ziggy.json.stringify(arena, .{
    .type = "queued-from-app",
    .queued = task_id,
}));
```

The frontend listens for every app event with `window.ziggy.onEvent`, and stops with `window.ziggy.removeEventListener(callback)`. The listener decides what an event means from its data:

```ts
window.ziggy.onEvent<IAppEvent>(event => {
    if (event.type === "queued-from-app") {
        ...
    }
});
```

Ziggy sends one app event of its own: when the user chooses a menu item that runs in the frontend (a `.ui` item), the `onEvent` listeners receive `{"type": "menu", "item": "<name>"}`, typed as `IMenuEvent` in `ziggy`, where `item` is the item's `.name`. An app must not send an event of its own with `type` set to `"menu"`. See [Menus](menus.md).

## Ziggy's own calls

Ziggy's own messages and events, the system messages and system events, are separate from the app's: they never reach the app's message handlers or an `onEvent` listener. An app cannot send or define one. The frontend reaches what they do only through these calls on `window.ziggy`:

| Call | What it does |
|---|---|
| `addTask(task)`, `cancelTasks(source)` | Queue a task and cancel the tasks of a source. See [Tasks](tasks.md). |
| `onTaskEvent(callback)`, `onTaskCompleted(callback)` | Hear what a task sends while it runs and how it ended. See [Tasks](tasks.md). |
| `getPlatform()` | Resolves with whether the app is on a desktop or a mobile device (`platformKind`), and the operating system and processor (`os`, `arch`). |
| `onCoreError(callback)` | Hears of a message that failed with no message response to carry the error, such as one that is not JSON or was sent with `send`, with the `error`. With no listener, the error is logged to the console. |
| `getPathForFile(file)` | The real path of a file dropped on the window. It asks the backend for the paths of the last drop, so the frontend never does that itself. |
| `onTestCommand(callback)`, `sendTestResult(requestId, result)`, `testUiReady()` | The test hooks, in a test hooks build only. See [Testing your app](testing.md). |

Each `on...` call has a `remove...Listener` call beside it that takes the same callback, such as `removeTaskEventListener`.

## See also

- [Tasks](tasks.md): slow work, and a message answered by a task.
- [The message bridge](../development/architecture.md#the-message-bridge): how a message and its message response travel between the frontend and the backend, and what they look like on the way.
- [Claude Code commands](claude-code-commands.md): `/ziggy:add-message`.
