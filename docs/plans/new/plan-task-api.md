# Give tasks their own API, separate from messages

## Overview

Today the UI queues a task by sending an ordinary message on the `add-task` channel (`window.ziggy.send("add-task", {...})`), cancels with a message on `cancel-tasks`, and hears about tasks through ordinary events on the `task-message` and `task-completed` channels (`window.ziggy.onMessage`). Tasks are a different thing from messages: a message gets a message response, while a task runs on a worker thread and reports through events. Mixing them makes the UI code hard to read and lets the UI make up task ids that can collide. This plan gives `window.ziggy` its own task functions (`addTask`, which assigns and returns the task id, `cancelTask`, which cancels one task by that id, `cancelTasks`, which cancels every task of a source, and `onTaskEvent`) and gives tasks their own kind of message and event between the UI and the core, so tasks no longer travel as channel messages at all. The docs already describe `addTask` and `onTaskEvent` (`docs/quick-start.md` and `docs/user-guide/tasks.md`). Backward compatibility is not required.

## Issues

## Steps

1. **Write the documentation.** Bring the docs to the API as intended, so the human can review it before any code changes:
   - `docs/user-guide/tasks.md`: "Queuing a task from the UI" shows `const taskId = window.ziggy.addTask({ taskType, source, data, priority })` and says the id is assigned by Ziggy and returned at once. "Receiving the events" uses `window.ziggy.onTaskEvent("task-message", ...)` and `window.ziggy.onTaskEvent("task-completed", ...)`. "Cancelling" uses `window.ziggy.cancelTask(taskId)` to cancel one task by the id `addTask` returned, and `window.ziggy.cancelTasks(source)` to cancel every task of a source. The sequence diagram's first arrow uses `addTask`, and the table of files no longer says `core.zig` holds the `add-task` and `cancel-tasks` channels.
   - `docs/quick-start.md`: the task snippet uses `addTask` (returning `taskId`) and `onTaskEvent`, and the paragraph after it says what `addTask` returns.
   - `docs/user-guide/channels.md`: say that tasks are not reached through channels and point to the Tasks guide.
   - `docs/development/architecture.md`: describe the task message the UI sends and the task event the core delivers as their own kinds, beside the message, message response and event.
   - `docs/glossary.md`: check the Task and Event entries still hold.
   - STOP when the draft is written. Do not continue to step 2. Wait for the human to review and approve the documentation. If the human revises it, revise the remaining steps to match before continuing.

2. **Add the types to `ziggy-ui`.** In `packages/ziggy/ui/src/ziggy-bridge.ts`:
   - Add `IAddTaskRequest` (fields `taskType`, `source`, `data`, optional `priority` of `"interactive" | "background"`), each field with a `//` comment.
   - Add `ITaskEventMap` mapping `"task-message"` to `ITaskMessageEvent<IJsonValue>` and `"task-completed"` to `ITaskCompletedEvent`.
   - Add to `IZiggyBridge`: `addTask(request: IAddTaskRequest): string`, `cancelTask(taskId: string): void`, `cancelTasks(source: string): void` and `onTaskEvent<TEvent>(kind: "task-message" | "task-completed", callback: IMessageCallback<TEvent>): void`, each with a `//` comment.
   - Export the new types from `packages/ziggy/ui/src/index.ts`.
   - Run `mise exec -- bun run compile` from the repository root. It must pass.

3. **Define the wire format.** Tasks travel as system messages and system events, the envelope written down in the comment block at the top of `packages/ziggy/core/src/lib/ziggy-inject.js`, so no new field or kind is added. Write down there the system messages and events the task functions use:
   - From the UI: `{ "kind": "system", "name": "add-task", "data": { "taskId", "taskType", "source", "data", "priority" } }` to queue a task (the `taskId` is the one `addTask` assigns), `{ "kind": "system", "name": "cancel-task", "data": "<taskId>" }` to cancel one task and `{ "kind": "system", "name": "cancel-tasks", "data": "<source>" }` to cancel every task of a source.
   - From the core: the system events `{ "kind": "system", "name": "task-message", "data": {...} }` and `{ "kind": "system", "name": "task-completed", "data": {...} }`.

4. **Queue and cancel tasks from system messages in the core.** In `packages/ziggy/core/src/lib/system-messages.zig`:
   - Keep `add-task` and `cancel-tasks` in `system_messages`. A failure of `add-task` (missing `taskId`, `taskType` or `source`, unknown priority, unknown task type) is reported to the UI as a `task-completed` system event with status `failed` for that `taskId` when it has one, or as a `core-error` system event when it has none, so no failure is silent.
   - Add a `cancel-task` system message, which cancels the one task with that id. Read `TaskRunner` in `packages/ziggy/core/src/lib/task-runner.zig` for a way to cancel a single task by id. If there is none, add `TaskRunner.cancelTask(task_id: []const u8) !void`, which cancels the queued or running task with that id (and its children, as cancelling a source does) and returns `error.UnknownTask` when no task has it. Report that error to the UI as a `core-error` system event.
   - Keep `priorityFromText` as it is.
   - Run `mise exec -- zig build` and fix every compile error.

5. **Deliver task events as system events.** In `packages/ziggy/core/src/lib/task-runner.zig`, `emitTaskMessage` and `emitTaskCompleted` already build `{ "kind": "system", "name": "task-message", "data": {...} }` and `{ "kind": "system", "name": "task-completed", "data": {...} }`. Confirm it by reading them, and change them only if the data the task functions need differs. Leave the message response sent for a message answered by a task as it is. Run `mise exec -- zig build`.

6. **Add the task functions to `window.ziggy`.** In `packages/ziggy/core/src/lib/ziggy-inject.js`, build each on the script's private system part (`postSystem` and the system listeners), which is not on `window.ziggy`:
   - Change `addTask(request)` to assign the task id, post the `add-task` system message with it and return it. The id must not repeat within the page or after a reload while earlier tasks still run, so build it from a random prefix chosen when the script loads plus a counter (`crypto.getRandomValues` for the prefix, which every supported web view has).
   - Add `cancelTask(taskId)`: post the `cancel-task` system message.
   - Keep `cancelTasks(source)`: it posts the `cancel-tasks` system message.
   - Add `onTaskEvent(kind, callback)`, which adds the callback as a system listener for the `task-message` or `task-completed` system event.
   - `receive` already hands a system event only to the system listeners for its name, never to `onEvent`; no change is needed there.
   - Add the new functions to the frozen `window.ziggy` object.
   - The dev client (`packages/ziggy/dev/src/lib/dev-client.js`) only stands in for the native handle, so it needs no change. Confirm by reading it.

7. **Move every user of the old channels.** Replace `send("add-task", ...)`, `send("cancel-tasks", ...)` and `onMessage("task-message" | "task-completed", ...)` with the new functions in:
   - `apps/ziggy-template/ui/src/main.ts` (drop `nextTaskNumber` and use the id `addTask` returns).
   - `apps/ziggy-test-app/ui/src` (every file that queues, cancels or listens for tasks; find them with `git grep -n 'add-task\|cancel-tasks\|task-message\|task-completed' -- apps`).
   - The `/ziggy:add-task` command, `.claude/commands/ziggy/add-task.md`, if it names the old calls.
   - Any smoke test, Zig test or script that sends or reads the old channels: find them with `git grep -n 'add-task\|cancel-tasks\|"task-message"\|"task-completed"' -- ':!docs'`.
   - Run `mise exec -- bun run compile`, `mise exec -- bun run test`, `mise exec -- bun run compile:zig` and `mise exec -- bun run test:zig` from the repository root. All must pass.

8. **Run the smoke tests and the phone suites.** The core library and the injected script changed, so run from the repository root `mise exec -- bun run test:smoke`, `mise exec -- bun run test:smoke:dev`, `mise exec -- bun run test:zig:android` and `mise exec -- bun run test:smoke:and` (run `adb devices` first and read it: if no serial is in the `device` state, say so and stop). Run the template's smoke tests with `mise exec -- bun run --filter=ziggy-template test:smoke`. The iOS and macOS suites need a Mac: say they were not run.

9. **Update the documentation.** Re-read every doc from step 1 against the final code and correct anything that changed during implementation: the exact signatures in `ziggy-bridge.ts`, the wire format in `ziggy-inject.js`, how a failed `addTask` is reported and the id format.

## Unit Tests

- `packages/ziggy/ui/src/test/ziggy-inject.test.ts`:
  - `addTask` posts a `task` message carrying the fields given and a `taskId`, and returns that `taskId`.
  - Two calls to `addTask` return different ids.
  - `cancelTask` posts a `cancelTask` message with the task id.
  - `cancelTasks` posts a `cancelTasks` message with the source.
  - `onTaskEvent` callbacks run for a received `taskEvent` of their kind, and not for the other kind or for a channel event of the same name.
  - A `taskEvent` does not reach `onMessage` listeners.
- `packages/ziggy/core/src/test/dispatcher.test.zig`:
  - A `task` message queues the task (the runner reports it) and sends no reply.
  - A `task` message with no `taskType` produces a failed `task-completed` task event for its `taskId`.
  - A `task` message with no `taskId` produces a `core-error` event.
  - A `cancelTask` message cancels that one task and leaves the other tasks of its source running.
  - A `cancelTask` message for an id the runner does not know is reported as a `core-error` event.
  - A `cancelTasks` message cancels the tasks of that source.
  - A channel message on `add-task` or `cancel-tasks` now fails as `UnknownChannel`.
- `packages/ziggy/core/src/test/task-runner.test.zig`, if step 4 adds `TaskRunner.cancelTask`: it cancels a queued task, a running task (which stops at its next `isCancelled` check) and that task's children, leaves other tasks alone and fails with `UnknownTask` for an id it does not know.
- `packages/ziggy/core/src/test/task-runner.test.zig`: `task-message` and `task-completed` are emitted with a `taskEvent` field, and the reply to a task channel request is unchanged.
- Rename `addTaskHandler` and `cancelTasksHandler` in any existing test that calls them, and keep `priorityFromText`'s tests.

## Smoke Tests

- The template's hello world smoke test (`apps/ziggy-template/smoke-tests/hello-world-app/test.sh`) presses the task button and waits for the task's output and "The task ended: succeeded", so it covers `addTask`, `onTaskEvent` and the new wire format end to end. It must pass unchanged.
- Ziggy's smoke tests drive the test app's tasks, including cancelling and child tasks. They must pass on the desktop, in dev mode and on Android.

## Verify

- `git grep -n 'send("add-task"\|send("cancel-tasks"\|onMessage("task-\|onMessage<ITask' -- ':!docs/plans'` prints nothing.
- `mise exec -- bun run compile` and `mise exec -- bun run compile:zig` succeed.
- `mise exec -- bun run test` and `mise exec -- bun run test:zig` pass.
- `mise exec -- bun run test:smoke`, `test:smoke:dev`, `test:zig:android` and `test:smoke:and` pass, and the template's `test:smoke` passes.

## Notes

- Decisions taken in this plan for the human to confirm at step 1: tasks are separated on the wire as well as in the API; cancelling becomes `cancelTask(taskId)` for one task and `cancelTasks(source)` for a source; `onTaskEvent` takes the event kind as its first argument; `addTask` assigns the id in the UI and returns it synchronously.
- Assigning the id in the UI keeps `addTask` synchronous. Assigning it in the core would need a reply, which would make `addTask` return a promise and bring back the message response the change is meant to remove.
- Task channels (`TaskChannelEntry`, a request answered by a task) stay as they are: the UI sees them as ordinary `invoke` calls.
- The example apps (`ziggy-example-vite` and `ziggy-example-rsbuild`) pin Ziggy to a version tag and use the old calls. They move to the new API when a Ziggy release has it, as a separate piece of work.
