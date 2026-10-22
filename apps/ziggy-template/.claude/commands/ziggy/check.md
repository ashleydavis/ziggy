---
description: Run every check a Ziggy app has that this machine can run (type checks, unit tests and smoke tests), and fix what fails.
---

# Check a Ziggy app

Run the app's checks from its directory, one after another, cheapest first. Read the app's `package.json` scripts first: the names below are the ones the Ziggy template has, and an app may have renamed or added some.

1. `bun run compile`: type checks the frontend.
2. `bun run test`: the frontend's unit tests.
3. `bun run compile:zig`: builds the backend and the native apps.
4. `bun run test:zig`: the backend's unit tests.
5. `bun run test:smoke`: the smoke tests on this machine's desktop platform.
6. `bun run test:smoke:android`, when an Android emulator or device is attached (`adb devices` lists one).
7. `bun run test:smoke:ios`, on a Mac with a simulator or a connected device.

A run that fails is a bug in the app or in its test: find the cause and fix it, then run that check again. Never skip, loosen or delete a test to make it pass.

## Report

Say which checks ran and passed, which failed and what was fixed, and which could not run on this machine and why (no emulator attached, not a Mac). Never report a check as passing that did not run.
