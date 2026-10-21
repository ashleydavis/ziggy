---
description: Add a background task type to a Ziggy app: the backend's handler, its registration, how the UI queues it and follows its progress, and the tests.
---

# Add a task to a Ziggy app

The human says what the work is, what it takes as input and what it produces. If they have not, ask, and wait for the answer.

Read Ziggy's guide [Tasks](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/tasks.md) first, all of it, and the app's existing task handlers (in the template, `backend/src/lib/hello-world-backend.zig`). Write the new task the way those are written.

## Add it

1. Write the handler in `backend/src/lib`, as the guide's "Writing a handler" says. Report progress as the work goes, and check for cancellation between steps that take a while.
2. Split work that has many independent pieces into child tasks, as the guide's "Child tasks" says.
3. Register the handler under its task type in `.tasks` of the app's `ziggy.core.App` in `backend/src/app.zig`, or with `core.registerTask` for a task type registered only while the app runs, as the guide's "Registering a handler" says.
4. Write the handler's unit tests in `backend/src/test`, and watch each one fail with the handler broken.
5. Queue it from the UI and follow its events, as "Queuing a task from the UI" and "Receiving the events" say. When the work answers a message the UI sends with `invoke`, have that message's handler return `.task` instead, as "A message answered by a task" says. Keep any logic beyond the calls in a plain function under `ui/src/lib`, with unit tests.
6. When it must keep running after the window closes, make it a keep-alive task type, as Ziggy's Tasks guide says under "Keep-alive tasks".
7. Run `/ziggy:check`.

A task that fails ends with an error naming what went wrong. Never end a task as done when its work did not happen.
