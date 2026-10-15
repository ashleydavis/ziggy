# Channels

Terms are defined in the [glossary](../glossary.md).

A channel is how the UI and the backend talk. The UI sends a message on a channel, a Zig function in the backend handles it and the backend sends back a message response. The backend can also send events to the UI on a channel. All of it passes inside the app, through the native app: there is no HTTP and no network.

The `/ziggy:add-channel` Claude Code command adds a channel to an app by following this guide.

## Writing a handler

A channel's handler is a Zig function that takes the backend, an arena and the data the UI sent, and returns the JSON text of its message response. This one, the template's hello world in `backend/src/lib/hello-world-backend.zig`, returns a greeting for the name it was sent:

```zig
const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");

pub fn helloWorldHandler(
    core: *ziggy.core.Core,
    arena: std.mem.Allocator,
    data: std.json.Value,
) anyerror![]const u8 {
    _ = core;
    const name = ziggy.json.getString(data, "name") orelse {
        return error.MissingName;
    };
    return try ziggy.json.stringify(arena, .{
        .greeting = try std.fmt.allocPrint(arena, "Hello {s}, from Zig on {s}", .{
            name,
            @tagName(builtin.os.tag),
        }),
    });
}
```

Allocate from `arena`. It is freed once the message response has been sent.

Define the types of the message's data and of the message response beside the handler, so the handler is where its payload is described.

A handler runs on the thread that handles every message from the UI, so it must be quick. Anything slow, such as reading many files, hashing or waiting on the network, is a task instead. A channel can also be handled by a task, so a slow message response does not hold up the other messages: the Tasks guide's "A message handled by a task" says how.

## Registering it

The app gives Ziggy its channels in `backend/src/handlers.zig`, each with its name and its handler:

```zig
pub const app = ziggy.core.AppHandlers{
    .channels = &[_]ziggy.core.ChannelEntry{
        .{
            .name = "hello-world",
            .handler = hello_world_backend.helloWorldHandler,
        },
    },
    ...
};
```

## Sending a message from the UI

The UI sends a message with `window.ziggy.invoke`, which resolves with the data of the message response:

```ts
const response = await window.ziggy.invoke<IHelloWorldResponse>("hello-world", {
    name: "world",
});
```

`window.ziggy.send(channel, data)` sends a message that gets no message response. The types of `window.ziggy` come from the `ziggy-ui` package.

## When a handler fails

A handler that fails returns a Zig error. `invoke` then rejects with an `Error` whose message is the error's name, such as `MissingName`, because a Zig error carries no text of its own. A message on a channel the backend does not know gets an error message response too, never silence.

An app that can say more about a failure gives the backend a `describe_error` function in its `AppHandlers`. The backend calls it with the error a channel's handler or a task's handler returned, and uses the text it returns in place of the error's name. It returns null for an error it has nothing to say about:

```zig
pub fn describeError(err: anyerror) ?[]const u8 {
    if (err == error.Refused) {
        return "The app refused, as the refuse channel always does.";
    }
    return null;
}
```

## Sending an event to the UI

The backend sends an event with `core.deliver`, as JSON with the channel and the data. Here a handler tells the UI it queued a task:

```zig
core.deliver(try ziggy.json.stringify(arena, .{
    .channel = "app-event",
    .data = .{
        .queued = task_id,
    },
}));
```

The UI listens for the events on a channel with `window.ziggy.onMessage`, and stops with `window.ziggy.removeAllListeners(channel)`:

```ts
window.ziggy.onMessage<IAppEvent>("app-event", event => {
    ...
});
```

## Ziggy's own channels

These channels belong to Ziggy. Every other channel belongs to the app.

- `add-task` and `cancel-tasks` from the UI, and the `task-message` and `task-completed` events: see [Tasks](tasks.md).
- `get-platform`: says whether the app is on a desktop or a mobile device (`platformKind`), and the operating system and processor (`os`, `arch`).
- `get-dropped-paths`: the real paths of the files in the last drop on the window. `window.ziggy.getPathForFile` uses it, so the UI never sends it itself.
- `core-error`: an event reporting a message that failed with no message response to carry the error, such as one that is not JSON or was sent with `send`. It is logged to the console when the UI has no listener for it.
- `menu-action`: an event saying a menu item that is the app's own was chosen.
- `test-command`: an event carrying a command from a smoke test, in a test hooks build only.

## See also

- [Tasks](tasks.md): slow work, and a message handled by a task.
- [The message bridge](../development/architecture.md#the-message-bridge): how a message and its message response travel between the UI and the backend.
- [Claude Code commands](claude-code-commands.md): `/ziggy:add-channel`.
