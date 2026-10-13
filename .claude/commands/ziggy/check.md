---
description: Run every check a Ziggy app has that this machine can run (type checks, unit tests, the core's tests and the smoke tests), and fix what fails.
---

# Check a Ziggy app

Run the app's checks from its folder, one after another, cheapest first. Read the app's `package.json` scripts first: the names below are the ones the Ziggy template has, and an app may have renamed or added some.

1. `bun run compile`: type checks the UI.
2. `bun run test`: the UI's unit tests.
3. `bun run compile:zig`: builds the core and the native apps.
4. `bun run test:zig`: the core's unit tests.
5. `bun run test:smoke`: the smoke tests on this machine's desktop platform.
6. `bun run test:smoke:dev`: the smoke tests in dev mode, with the UI in a headless Chrome or Chromium.
7. `bun run test:smoke:and`, when an Android emulator or device is attached (`adb devices` lists one).
8. `bun run test:smoke:ios` and `bun run test:zig:ios`, on a Mac with a simulator.

A run that fails is a bug in the app or in its test: find the cause and fix it, then run that check again. Never skip, loosen or delete a test to make it pass.

## Report

Say which checks ran and passed, which failed and what was fixed, and which could not run on this machine and why (no emulator attached, not a Mac). Never report a check as passing that did not run.
