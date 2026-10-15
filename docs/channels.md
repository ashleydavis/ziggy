# Channels

Terms are defined in the [glossary](glossary.md).

A channel is how the UI and the backend talk. The UI sends a message on a channel, a Zig function in the backend handles it and the backend sends back a message response. The backend can also send events to the UI on a channel. All of it passes inside the app, through the native app: there is no HTTP and no network.

The `/ziggy:add-channel` Claude Code command adds a channel to an app by following this guide.

## Writing a handler

A channel's handler is a Zig function that takes the backend, an arena and the data the UI sent, and returns the JSON text of its message response. This one, the template's hello world in `backend/src/lib/hello-world-backend.zig`, answers with a greeting for the name it was sent:

```zig
const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");

pub fn helloWorldHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = core;
    const name = ziggy.json_util.getString(data, "name") orelse {
        return error.MissingName;
    };
    return try ziggy.json_util.stringify(arena, .{
        .greeting = try std.fmt.allocPrint(arena, "Hello {s}, from Zig on {s}", .{
            name,
            @tagName(builtin.os.tag),
        }),
    });
}
```

Allocate from `arena`. It is freed once the message response has been sent.

Define the types of the message's data and of the message response beside the handler, so the handler is where its payload is described.

A handler runs on the thread that handles every message from the UI, so it must be quick. Anything slow, such as reading many files, hashing or waiting on the network, is a task instead. A channel can also be answered by a task, so a slow answer does not hold up the other messages: the Tasks guide's "A message answered by a task" says how.

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
        return "The app refused, as it was asked to.";
    }
    return null;
}
```

## Sending an event to the UI

The backend sends an event with `core.deliver`, as JSON with the channel and the data. Here a handler tells the UI it queued a task:

```zig
core.deliver(try ziggy.json_util.stringify(arena, .{
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

## See also

- [Tasks](tasks.md): slow work, and a message answered by a task.
- [The message bridge](architecture.md#the-message-bridge): how a message, a message response and an event travel between the UI and the backend on each platform.
- [Protocol](architecture.md#protocol): the channels that belong to Ziggy itself.
- [Claude Code commands](claude-code-commands.md): `/ziggy:add-channel`.
