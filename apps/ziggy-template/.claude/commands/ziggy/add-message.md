---
description: Add a message the UI can send to a Ziggy app's backend and get a message response to: its handler, its registration in the app's app.zig, the UI's call and their tests.
---

# Add a message to a Ziggy app

The human says what message the UI needs to send the backend and what message response comes back. If they have not, ask, and wait for the answer.

Read Ziggy's guide [Messages](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/messages.md), including its "Ziggy's own calls" section, and the app's own `backend/src/app.zig` (its `ziggy.core.App` declaration) and its handlers under `backend/src/lib` (in the template, `backend/src/lib/hello-world-backend.zig`) before writing anything. Write the new code the way those are written.

## Decide whether it is a new message

- Prefer an existing message when one already does what is needed. Otherwise give the new action its own message name: the message name is what Ziggy picks the handler by, so an action's name does not go in the data.
- Anything that takes long (reading many files, hashing, network) is a task, not a message its handler answers itself, because every message handler runs on the thread that handles every UI message. Use `/ziggy:add-task` for that, or have the handler answer with a task by returning `.task` (the Tasks guide's "A message answered by a task").
- The new message is an app message. Never try to handle or send a system message, one of Ziggy's own (adding and cancelling tasks, the platform, the menu items the native app passes on, dropped files, the test hooks), from the app. They never reach the app's message handlers. The UI reaches them only through their own calls on `window.ziggy`.

## Add it

1. Choose the message name, a string such as `hello-world`. Define the request struct the message's data is parsed into and the response struct beside the handler, with a `//` comment on every field. The name is not part of the data.
2. Write the handler in `backend/src/lib` in one of the forms the Messages guide lists under "What a handler returns", and register it under its name in `.messages` of the app's `ziggy.core.App` in `backend/src/app.zig`. A message registered only while the app runs uses `core.registerMessage` instead. Ziggy answers a name nothing is registered under with `UnknownMessageName` and data that does not fit the request with `InvalidMessageData`. The handler does not check either.
3. Write its unit tests in `backend/src/test`, creating the backend with the app's `app` and posting the message to it as the UI would (as the template's `backend/src/test/hello-world-backend.test.zig` does), and watch each one fail before the function is written or with the function broken.
4. Call it from the UI with `window.ziggy.invoke("<message name>", data)`, passing `null` as the data when there is none, or with `window.ziggy.send("<message name>", data)` when it needs no message response. Keep any logic beyond the call in a plain function under `ui/src/lib`, with unit tests.
5. Run `/ziggy:check`.

A handler that fails returns a Zig error, and the UI gets an error message response naming it. Never return a success value for a failure.
