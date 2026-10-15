# Document the types in ziggy-ui

## Overview

`ziggy-ui` (`packages/ziggy/ui`) is the npm package an app's UI takes its types from: the type of `window.ziggy` (`IZiggyBridge`) and the types of the data the backend sends. No doc lists them, says what each is for, or says that importing a type from `ziggy-ui` is what declares `window.ziggy` for TypeScript. A UI author has to read `packages/ziggy/ui/src/ziggy-bridge.ts` to find out. This plan writes that documentation, taken from the code and its comments, and links it from the guides that send the reader to `ziggy-ui`. It changes no code.

## Issues

## Steps

1. Write the documentation, then STOP for the human's review:
   - Add a section "The UI's types (ziggy-ui)" to `docs/integrating-ziggy.md`, after "The UI (package.json)". It covers:
     - How the UI gets the types: `import type { ... } from "ziggy-ui"`, and that `ziggy-bridge.ts`'s `declare global` gives `Window` its `ziggy` property, so `window.ziggy` is typed in any file of a program that imports from `ziggy-ui` once.
     - `IZiggyBridge`, one line per method, from its comments: `invoke<TReply>(channel, data)`, `send(channel, data)`, `onMessage<TData>(channel, callback)`, `removeAllListeners(channel)` and `getPathForFile(file)`.
     - Every other exported type, one line each: `IJsonObject`, `IJsonValue`, `IMessageCallback<TData>`, `ITaskMessageEvent<TMessage>`, `ITaskCompletedEvent`, `ITaskResult` (each field) and `ITaskError`.
     - Which event each event type belongs to (`task-message`, `task-completed`), and that the app defines the types of its own messages, message responses and events beside its handlers.
   - In `docs/channels.md` ("Sending a message from the UI") and `docs/tasks.md`, replace any sentence that only says the types come from `ziggy-ui` with nothing, and add the new section to their "See also".
   - In `docs/user-guide.md`, list the new section under "Also".
   - Read every line against `packages/ziggy/ui/src/ziggy-bridge.ts` and `packages/ziggy/ui/src/index.ts`, so the doc names no type, field or method the package does not export.
   - STOP. Wait for approval. If the human moves the section to a doc of its own or changes what it covers, revise the steps below to match.
2. Check every link and anchor the new section and its "See also" entries use resolves.
3. Update the documentation from step 1 so it matches the code as it then stands, including any change to `ziggy-bridge.ts` made since step 1.

## Unit Tests

- None: the change is documentation only, and no code changes.

## Smoke Tests

- None: the change is documentation only.

## Verify

- Every type, field and method the new section names is exported by `packages/ziggy/ui/src/index.ts` (check by reading `ziggy-bridge.ts`), and every one it exports is named.
- Every link and anchor in the changed docs resolves.
- `bun run compile` and `bun run test` still pass (they should be untouched, as no code changes).

## Notes

- The plan `plan-one-message-handler.md` would change `IZiggyBridge` (`invoke` and `send` without a channel, `onEvent` and Ziggy's own calls). If that plan goes ahead first, this section documents the new API; if this one goes first, that plan's documentation step updates the section.
- The types are taken from the comments in `ziggy-bridge.ts`, which `CLAUDE.md` requires on every interface and field, so the doc and the code describe each type the same way.
