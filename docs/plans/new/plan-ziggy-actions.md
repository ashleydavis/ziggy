# Actions, and building an app on Ziggy the way Rails builds a web app

## Overview

Give Ziggy one central notion, the action: a named piece of an app's work, written once in the app's core, that runs the same way whether it is started from the command line, from the UI (a menu item, a keyboard shortcut, or a button, run as a background task) or by an AI agent through an MCP server. With actions as the unit an app is built from, generators can scaffold an app and add to it the way Rails does: a new app from the template, then one command per new action, each arriving with its tests and wired into every surface.

## Issues

## Steps

1. Write the documentation for actions as they are intended to work, and STOP. Draft `docs/actions.md` (what an action is, how an app declares one, and how each surface runs it) and the matching changes to `docs/architecture.md`, `docs/building-your-app.md`, `docs/claude-code-commands.md` and the guide list in `README.md`. Where the design is undecided (see Notes), write the question into the draft rather than an answer. Do not continue to later steps: wait for the human to review the draft. Their revisions decide the architecture, and the steps below must be revised to match before any code is written.
2. Add the action to Ziggy's core as the approved documentation describes, with unit tests for every new function.
3. Run actions from the UI: from the menu and its shortcuts, and from the UI's own code, as background tasks the UI can follow and cancel. Unit test the core's part and cover each path with a smoke test.
4. Run actions from the command line, as the approved documentation describes. Cover it with a smoke test that runs an action and checks its result.
5. Run actions through an MCP server, as the approved documentation describes, using a maintained MCP SDK rather than a hand-written protocol. Cover it with a smoke test that lists the actions as tools and calls one.
6. Add a generator that adds an action to an app, with its tests, and a `/ziggy:add-action` Claude Code command over it. Cover the generator with a test that adds an action to a copy of the template and runs the copy's checks.
7. Give the template one action, run from its menu, a shortcut and one button, with the smoke tests that exercise it.
8. Update the documentation from step 1 to match what was built, and the Claude Code commands that refer to channels and tasks where actions now replace them.

## Unit Tests

Every new or changed function in the core, the command line runner and the generator gets a unit test, decided once the architecture is approved in step 1.

## Smoke Tests

- An action chosen from the menu, and by its shortcut, runs as a task and its result reaches the UI.
- An action started by a button in the UI runs as a task and its result reaches the UI.
- An action run from the command line prints its result and exits with success, and an action that fails exits with failure and says why.
- An MCP client lists the app's actions as tools and calls one.
- An action added by the generator to a copy of the template passes the copy's checks.

## Verify

- The TypeScript compiles and the Zig builds on every target (`bun run compile`, `bun run compile:zig`).
- All unit tests pass (`bun run test`, `bun run test:zig`).
- All smoke tests pass on Linux, in dev mode and on Android (`bun run test:ziggy-template`, `bun run test:ziggy-template:dev`, `bun run test:ziggy-template:and`).

## Notes

Undecided, for the human to settle in step 1:

- How an app declares an action, and what an action carries (its name, a description, what its input and output hold, its menu placement and shortcut, which surfaces may run it).
- How actions relate to the existing channels, task types and menu actions: whether they replace them or sit beside them.
- Where the command line runs an action: in a running copy of the app, or in a core of its own with no window, and which data it acts on.
- Where the MCP server runs and how it reaches the app's actions, and which MCP SDK it uses.
- How the generator is written and where its templates live.
- Whether the template becomes minimal before this work (a pending question), which changes what step 7 starts from.
