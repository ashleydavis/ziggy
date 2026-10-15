# Replace channels with one message handler

## Overview

Today an app gives Ziggy's core a table of channels (`AppHandlers.channels`, a list of `ChannelEntry` name and handler pairs) and a table of task channels (`AppHandlers.task_channels`), and every UI message carries a `channel` name that the core routes on. This plan removes channels. The app gives the core one Zig function, `handle_message`, that receives every message the UI sends and does what it likes with the payload, and the UI sends and listens without naming a channel. Ziggy's own messages and events (tasks, the platform, menus, dropped files, the test hooks) stay inside Ziggy and get their own calls on `window.ziggy`, so an app never sees them in its handler. The change is made in Ziggy first and tested against the two example apps on a local checkout, then released as a new version tag once the human approves, then taken by the examples from that tag, then by Photosphere.

## Issues

## Steps

### Phase 1: documentation and the Photosphere change list (stop for review)

1. Write the documentation for the new design, as it is intended to work, before any code changes:
   - Replace `docs/channels.md` with `docs/messages.md`: the app's one handler (`AppHandlers.handle_message`), its signature, what it returns (a message response, nothing, or "answered by a task"), sending a message from the UI (`window.ziggy.invoke(data)` and `window.ziggy.send(data)`), errors and `describe_error`, sending an event to the UI (`core.sendEvent`) and listening for it (`window.ziggy.onEvent`), and how an app that wants named messages routes them itself (a `type` field in the data and a `switch` in the handler, which the template does).
   - `docs/glossary.md`: remove "Channel" and "Dispatcher"; redefine "Message", "Message response", "Event" and "Handler" without channels; add "Message handler".
   - `docs/architecture.md`: "The message bridge" (the new message and event formats on the wire, which carry a `ziggy` field only for Ziggy's own messages and events), "Protocol" (Ziggy's own messages and events, now including `menu-action` and `core-error`, which it leaves out today), remove "Channels", and update "The file and folder dialogs", "Menus" and "Test hooks".
   - `docs/tasks.md`: rewrite "A message answered by a task" around `core.answerWithTask`, and the UI's task calls (`window.ziggy.addTask`, `cancelTasks`, `onTaskMessage`, `onTaskCompleted`).
   - `docs/quick-start.md` "4. See how it works", `docs/user-guide.md`, `docs/building-your-app.md`, `docs/claude-code-commands.md`, `docs/commands.md` if it names channels, `apps/ziggy-template/README.md`, `packages/ziggy/native/macos/README.md` (the menu-action JSON), `packages/ziggy/native/ios/README.md` (`ZiggyBridge.request` and `send`), `apps/ziggy-template/shells/macos/README.md` and `apps/ziggy-template/shells/windows/README.md`.
   - Rename `.claude/commands/ziggy/add-channel.md` to `.claude/commands/ziggy/add-message.md` and rewrite it for adding a message type to the app's handler.
   - Write `docs/plans/new/photosphere-one-message-handler-changes.md`: the list of changes Photosphere needs, from reading `/home/ash/projects/photosphere/photosphere` (see Notes for what to cover). It names each file and function and says what changes in it, so the human can judge the size of the Photosphere work before Ziggy changes.
   - STOP. Do not continue to Phase 2. Tell the human the docs and the Photosphere change list are ready to review. Wait for approval. If the human revises the docs or the design, revise every later step of this plan to match before writing any code.

### Phase 2: Ziggy's core

2. `packages/ziggy/core/src/lib/core.zig`: replace the channel types.
   - Remove `ChannelHandler`, `ChannelEntry`, `TaskChannelEntry`, `AppHandlers.channels` and `AppHandlers.task_channels`, and the `channels`, `task_channels` and `next_request_task` fields of `Core`.
   - Add `Message` (the parsed data of one UI message and its id, which the handler passes on unread), `MessageResult` (a union: `response` with the JSON text, `none`, and `answered_by_task`) and `MessageHandler` (`fn (core: *Core, arena: std.mem.Allocator, message: Message) anyerror!MessageResult`).
   - Add `AppHandlers.handle_message: MessageHandler`.
   - Keep `describe_error` and every other `AppHandlers` field as they are.
   - Build passes: `zig build test` compiles (later steps fix callers).
3. `core.zig` `Core.postMessage`: route on the new wire format.
   - A message with a `ziggy` field is one of Ziggy's own; look it up in the built-in table (today `ziggy_channels`, renamed `ziggy_messages`) and run it as today. An unknown `ziggy` name answers with an error (`UnknownZiggyMessage`).
   - Any other message goes to `handle_message`. `response` sends the message response when the message has an id; `none` sends nothing (and, when the message has an id, an empty successful response, so `invoke` never waits forever); `answered_by_task` sends nothing now.
   - Remove `MissingChannel` and `UnknownChannel`. Keep `InvalidMessage`, `describe_error` and the `core-error` event for a failure with no id.
4. `core.zig`: replace `answerWithTask(entry, ...)` with the public `Core.answerWithTask(self: *Core, message: Message, task_type: []const u8, data_json: []const u8) !MessageResult`. It refuses a message with no id (`MessageHasNoId`), queues the task with the message's id as the task's `reply_id_json` exactly as today, and returns `answered_by_task`. `task-runner.zig` `emitReply` is unchanged.
5. `core.zig`: add `Core.sendEvent(self: *Core, arena: std.mem.Allocator, data_json: []const u8) !void`, which wraps the data as an app event and delivers it. Ziggy's own events (`task-message`, `task-completed`, `menu-action`, `core-error`, `test-command`) are built with the `ziggy` field: change `emitTaskMessage`, `emitTaskCompleted` (`task-runner.zig`), `menuActionHandler`, `reportError` (`core.zig`) and `TestControl.askUi` (`test-control.zig`).
6. Unit tests for Phase 2 (see Unit Tests): rewrite `packages/ziggy/core/src/test/dispatcher.test.zig` and `helpers.zig` (`createCore` takes a test `handle_message` in place of the `echo`, `fail` and task channel tables), and update `task-runner.test.zig`, `queue-backend.test.zig` and `test-control.test.zig` where they assert the event JSON. Run `bun run test:zig` from the root; every test passes, and each new test is watched failing first.

### Phase 3: the UI script, its types and the native apps

7. `packages/ziggy/core/src/lib/ziggy-inject.js`: `invoke(data)` posts `{id, data}`; `send(data)` posts `{data}`; `onEvent(callback)` and `removeEventListener(callback)` for app events; Ziggy's own calls post or listen with the `ziggy` field: `addTask(task)`, `cancelTasks(source)`, `getPlatform()`, `onTaskMessage`, `onTaskCompleted`, `onMenuAction` and their removers, and the drop handler's `get-dropped-paths`. The test hook calls (`test-command`, `test-result`, `test-ui-ready`) become `onTestCommand`, `sendTestResult` and `testUiReady`, which post with the `ziggy` field. `receive` sends a message response to its pending `invoke`, a `ziggy` event to its listeners and anything else to the `onEvent` listeners; a `core-error` with no listener still goes to `console.error`.
8. `packages/ziggy/ui/src/ziggy-bridge.ts`: change `IZiggyBridge` to match step 7; add the types of Ziggy's events that have none today (`IMenuActionEvent`, `ITestCommandEvent`, `ICoreErrorEvent`) and of `addTask`'s argument; keep `ITaskMessageEvent`, `ITaskCompletedEvent` and `ITaskResult`. Update `packages/ziggy/ui/src/test/ziggy-inject.test.ts` and `dev-client.test.ts`. Run `bun run compile` and `bun run test`.
9. Native apps that write `{"channel":"menu-action"}` write `{"ziggy":"menu-action"}` instead: `performAction` in `packages/ziggy/native/linux/src/lib/shell.zig`, `MenuActionMessage` and `menuActionMessage` in `packages/ziggy/native/windows/src/lib/actions.zig`, `ZiggyBridge.postMenuAction` in `packages/ziggy/native/macos/Sources/ZiggyNativeMacOS/ZiggyBridge.swift` and in `packages/ziggy/native/ios/Sources/ZiggyNativeIOS/ZiggyBridge.swift`, and `menuActionCallback` in `packages/ziggy/core/src/lib/jni.zig`. On iOS, `ZiggyBridge.send(channel:data:)` and `request(channel:data:completion:)` drop the `channel` argument and post `{data}` and `{id, data}`. Swift must still build with Xcode 14.2. Run `bun run compile:zig` (it checks the Windows native app compiles).

### Phase 4: the template

10. `apps/ziggy-template/core/src/handlers.zig`: replace `.channels` and `.task_channels` with `.handle_message = handleMessage`, a function that reads a `type` field from the message's data and calls the existing handler for it (`pingHandler`, `payloadStatsHandler`, `fileRoundtripHandler`, `failHandler`, `refuseHandler`, `taskStatsHandler`, `queueFromAppHandler`, `cancelFromAppHandler`), and for `pick-files`, `pick-folder` and `pick-file` returns `core.answerWithTask` with the picker task types. An unknown `type` returns an error (`UnknownMessageType`). Change the handlers in `core/src/lib/channels.zig` (rename to `core/src/lib/messages.zig`), `app-state.zig` and `pickers.zig` only where their signature or return value changes. `queueFromAppHandler` sends its `app-event` with `core.sendEvent`, with `type` in the data.
11. `apps/ziggy-template/ui/src/main.ts`: every `invoke(channel, data)` becomes `invoke({ type, ... })`; `send("add-task")` and `send("cancel-tasks")` become `addTask` and `cancelTasks`; `onMessage("task-message")`, `("task-completed")`, `("menu-action")` and `("test-command")` become the matching Ziggy calls; `onMessage("app-event")` becomes `onEvent` with a check of `type`; `invoke("test-result")` and `send("test-ui-ready")` become `sendTestResult` and `testUiReady`. Keep the text the UI writes to its event log unchanged, because the smoke tests read it.
12. Template tests: update `apps/ziggy-template/core/src/test/handlers.test.zig`, `app-state.test.zig`, `pickers.test.zig` and `media-server.test.zig` to send messages through `handleMessage` with a `type`; add a test of `handleMessage` for an unknown type. Update `smoke-tests/dev-only/22-hot-reload/test.sh` if it edits the renamed `channels.zig`. Run from the root: `bun run compile`, `bun run test`, `bun run test:zig`, `bun run compile:zig`, `bun run test:android-shell`, `bun run test:ziggy-template`, `bun run test:ziggy-template:dev`, and, after running `adb devices` and finding a serial in state `device`, `bun run test:ziggy-template:and` and `bun run test:zig:android`. Every one passes. macOS, iOS and Windows are tested by the release workflow when the human pushes; say so and do not report them as tested.

### Phase 5: the examples on the local Ziggy

13. In `../ziggy-example-vite` and `../ziggy-example-rsbuild`, point every part at the local checkout for testing, with the local path lines of `docs/integrating-ziggy.md`: `build.zig.zon` (`.path = "../ziggy"`), `package.json` (`file:../ziggy/packages/ziggy/ui`) and `shells/android/settings.gradle` (`includeBuild`). Leave the Xcode projects on their tag, because they cannot be built on Linux. Carry over every change step 10 to 12 made to the template (the handler, the UI, the tests). Run in each: `bun install`, `bun run compile`, `bun run test`, `bun run test:zig`, `bun run compile:zig`, `bun run test:smoke`, and the Android suites when `adb devices` shows a device. Every one passes.
14. STOP. Report the results of Phase 2 to 5 to the human and ask whether to release this as a new version of Ziggy. Do not commit, push or tag anything without the human's direction in that message.

### Phase 6: release, then the examples on the release

15. Only on the human's direction: the human commits and pushes Ziggy, the release workflow must pass on that commit, and the version tag is cut as `docs/releasing-ziggy.md` says, with a GitHub release that says what an app has to change (the "Moving to this version" text from step 1). The next version is the one after the latest `v*` tag.
16. In both examples, move every part from the local path to the new tag, following "Moving to a newer version" in `docs/integrating-ziggy.md`, including both Xcode projects and `shells/android/app/build.gradle`. Run the same checks as step 13 against the tag. Every one passes; the human pushes, and each example's release workflow covers macOS, iOS and Windows.

### Phase 7: Photosphere

17. In `/home/ash/projects/photosphere/photosphere`, make the changes listed in `docs/plans/new/photosphere-one-message-handler-changes.md` (as the human approved them in step 1), taking Ziggy from the new tag in every place it is pinned. Follow Photosphere's own `CLAUDE.md`. Run Photosphere's own compile, unit test and smoke test commands, and its Android suites when `adb devices` shows a device. Every one passes.

### Phase 8: documentation

18. Revise every doc from step 1 so it matches the final code, including anything that changed during Phases 2 to 7. Check every link and anchor resolves. Delete `docs/channels.md` if it still exists.

## Unit Tests

- `dispatcher.test.zig`: a message with an id reaches `handle_message` and its `response` comes back with the same id; a string id; a message with no id gets no response; `none` with an id gives an empty successful response; a handler error gives an error response with the error's name; `describe_error` text replaces the name, and null keeps it; malformed JSON gives `core-error`; each Ziggy message (`get-platform`, `add-task`, `cancel-tasks`, `menu-action`, `get-dropped-paths`) is handled by Ziggy and never reaches `handle_message`; an unknown `ziggy` name gives `UnknownZiggyMessage`; `test-result` and `test-ui-ready` are refused without the test hooks.
- `Core.answerWithTask`: the task's result arrives as the message's response; a failed task gives an error response; a message with no id gives `MessageHasNoId` and runs nothing.
- `Core.sendEvent`: delivers the data as an app event with no `ziggy` field.
- `task-runner.test.zig`, `test-control.test.zig`: `task-message`, `task-completed` and `test-command` carry the `ziggy` field.
- `ziggy-inject.test.ts`: `invoke(data)` posts `{id, data}` and resolves with the response; rejects with the error; `send(data)` posts `{data}`; `onEvent` gets app events and not Ziggy's; each Ziggy call posts its `ziggy` name; each Ziggy listener gets only its event; the removers remove; a dropped file still gets its path.
- Template `handleMessage`: each `type` reaches its handler; the picker types are answered by a task; an unknown `type` gives `UnknownMessageType`.
- The template handler tests in `handlers.test.zig`, `app-state.test.zig`, `pickers.test.zig` and `media-server.test.zig`, updated to the new message format.

## Smoke Tests

- The template's existing scenarios, unchanged in what they assert, on Linux, in dev mode and on Android here, and on macOS, iOS and Windows through the release workflow: they drive the real app and read its event log, so they cover the new UI calls end to end (`1-reply`, the task scenarios, `10-pickers`, `11-menu-ui-actions`, `21-app-facilities`, the drop scenarios and `8-release-has-no-hooks`).
- Each example's smoke tests, against the local Ziggy and again against the release.
- Photosphere's smoke tests against the release.

## Verify

- `bun run compile`, `bun run test`, `bun run test:zig`, `bun run compile:zig` and `bun run test:android-shell` pass in Ziggy.
- `bun run test:ziggy-template` and `bun run test:ziggy-template:dev` pass, and `bun run test:ziggy-template:and` passes when a device is attached.
- `grep -rn -E "ChannelEntry|task_channels|UnknownChannel|MissingChannel|\"channel\"" packages apps` finds nothing outside the dev host's WebSocket test payload.
- Both examples pass their compile, unit and smoke tests against the local Ziggy, then against the release.
- Photosphere passes its compile, unit and smoke tests against the release.
- Every doc link and anchor resolves.

## Notes

- The design in Phase 1 is a proposal for the human to change: the names (`handle_message`, `MessageResult`, `answerWithTask`, `sendEvent`, `onEvent`), the `ziggy` field that marks Ziggy's own traffic on the wire, the separate `window.ziggy` calls for tasks, menus and test hooks, and the template's `type` field are all open. The choice that matters most: whether Ziggy also ships an optional router helper (a name and function list an app can use as its `handle_message`), or leaves routing entirely to the app as this plan does.
- No native app reads the `channel` field of what the core delivers; they pass the JSON to `window.__ziggyReceive` unread. The only native code that names a channel is the menu-action message (step 9) and the iOS app-side `send` and `request`. The dev host passes messages through unread, so it needs no change beyond its tests.
- The Photosphere change list in step 1 must cover, from reading Photosphere: the pins (all on `v0.0.1`: `build.zig.zon`, `apps/photosphere-frontend/package.json`, both Xcode projects, `apps/photosphere/shells/android/app/build.gradle`); `packages-zig/photosphere-core/src/lib/handlers.zig` `appHandlers()` and its `channels` and `task_channels` tables, which become one handler (its `main-command` handler already dispatches on a field in the data, and is the model for it); `events.zig` `sendEvent`, the one place it builds events, and the direct send in `mcp-server.zig`; the UI's `lib/platform-provider-ziggy.tsx`, `lib/ziggy-queue-backend.ts`, `lib/renderer-log.ts`, `lib/mcp-tool-handler.tsx`, `lib/ziggy-test-transport.ts` and `main.tsx`; the Zig test helper `test-support.zig` (`request`, `requestOk`, `requestError`), which every core test sends its messages through, and the tests that assert `"channel"` in delivered events; the UI test fake `src/test/fake-ziggy.ts` and the tests that name channels; `menu.test.zig`'s check of the table lengths; the docs that describe channels (`docs/photosphere-on-ziggy.md`, `apps/photosphere-frontend/README.md`, `docs/development.md`, `apps/photosphere/README.md`, `CLAUDE.md` and the header comments of the core's lib files). It should also say that the Electron app shares the names only by convention through `IPlatformContext`, so it needs no change, and flag that the MCP handler invokes `import-directories`, which no Ziggy handler answers today.
- An app that queues a task from its handler today with `core.runner.addTask` keeps doing so; only answering a message with a task's result changes, to `answerWithTask`.
- Nothing in this plan may stage, commit, push or tag without the human's direction in the message being acted on. The Android emulators belong to the human: check `adb devices` before each Android run and never start or stop one.
- Backward compatibility is not required: apps move to the new version and its new API together.
