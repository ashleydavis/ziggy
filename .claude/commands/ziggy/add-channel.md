---
description: Add a request the UI can send to a Ziggy app's core and get an answer to: the core's handler, its registration, the UI's call and their tests.
---

# Add a channel to a Ziggy app

The human says what the UI needs to ask the core and what comes back. If they have not, ask, and wait for the answer.

Read Ziggy's guide [Ziggy architecture](https://github.com/ashleydavis/ziggy/blob/main/docs/architecture.md), sections "Channels" and "Protocol", and the app's own `core/src/handlers.zig` and `core/src/lib/channels.zig` before writing anything. Write the new code the way those are written.

## Decide whether it is a channel

- Prefer an existing channel. A named action sent through one channel that takes the action's name is better than a channel per action.
- Anything that takes long (reading many files, hashing, network) is a task, not a channel, because a channel's handler runs on the thread that handles every UI message. Use `/ziggy:add-task` for that, or a channel that queues a task (the guide's "A request answered by a task").

## Add it

1. Define the request's and the reply's types beside the handler.
2. Write the handler in `core/src/lib` and register it with the app's other handlers.
3. Write the handler's unit tests in `core/src/test`, and watch each one fail before the handler is written or with the handler broken.
4. Call it from the UI with `window.ziggy.invoke("<channel>", request)`. Keep any logic beyond the call in a plain function under `ui/src/lib`, with unit tests.
5. Run `/ziggy:check`.

A handler that fails returns a Zig error, and the UI gets an error reply naming it. Never answer a failure with a success value.
