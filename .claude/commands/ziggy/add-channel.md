---
description: Add a message the UI can send to a Ziggy app's backend and get a message response to: the backend's handler, its registration, the UI's call and their tests.
---

# Add a channel to a Ziggy app

The human says what message the UI needs to send the backend and what message response comes back. If they have not, ask, and wait for the answer.

Read Ziggy's guide [Channels](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/channels.md), including its "Ziggy's own channels" section, and the app's own `backend/src/handlers.zig` and its handlers under `backend/src/lib` (in the template, `backend/src/lib/hello-world-backend.zig`) before writing anything. Write the new code the way those are written.

## Decide whether it is a channel

- Prefer an existing channel. A named action sent through one channel that takes the action's name is better than a channel per action.
- Anything that takes long (reading many files, hashing, network) is a task, not a channel, because a channel's handler runs on the thread that handles every UI message. Use `/ziggy:add-task` for that, or a channel that queues a task (the guide's "A message handled by a task").

## Add it

1. Define the message's and the message response's types beside the handler.
2. Write the handler in `backend/src/lib` and register it with the app's other handlers.
3. Write the handler's unit tests in `backend/src/test`, and watch each one fail before the handler is written or with the handler broken.
4. Call it from the UI with `window.ziggy.invoke("<channel>", data)`. Keep any logic beyond the call in a plain function under `ui/src/lib`, with unit tests.
5. Run `/ziggy:check`.

A handler that fails returns a Zig error, and the UI gets an error message response naming it. Never return a success value for a failure.
