# Rename `log.@"error"` to `log.err`

## Overview
`error` is a reserved word in Zig, so the log's error function has to be called as `log.@"error"(...)`. Zig's own standard library names the same thing `std.log.err`. This plan renames the `ILog` function and its vtable field to `err`, so callers write `log.err("...")`, and updates every caller in Ziggy, the two examples and Photosphere. Backward compatibility is not required, so the old name is removed rather than kept beside the new one.

## Issues

## Steps

1. **Rename in Ziggy's log.** In `packages/ziggy/core/src/lib/task-queue/utils/log.zig`, rename the vtable field `@"error"` (line 57) to `err` and the `ILog` method `pub fn @"error"` (line 98) to `pub fn err`, and update every vtable that sets the field (`.@"error" = logError` and the others in `log.zig`, `file-log.zig`, the worker's `QueueLog` and any test log the compiler names). Leave `LogLevel.@"error"` and `console.@"error"` as they are (see Notes). Update the doc comments that name the function. Run `zig build test --summary all` in the Ziggy worktree; it must pass.

2. **Update Ziggy's callers.** Replace every `log.@"error"(` and `.@"error"(` call on an `ILog` or on `utils.log.log` in `packages/` and `apps/` (8 files in `packages/`, 1 in `apps/`, found with `grep -rn 'log\.@"error"(' packages apps`) with `.err(`. Run `zig build test --summary all` and `bun run test:everything`; both must pass.

3. **Update the examples.** In both example worktrees, replace any `log.@"error"(` with `log.err(` (none are there today; check with grep). Run each example's `bun run test:everything`.

4. **Update Photosphere's callers.** In the Photosphere worktree, replace every `log.@"error"(` call on the log (38 uses in 27 files under `packages-zig`, 98 uses in 27 files under `apps`) with `log.err(`, including any local log interface that wraps Ziggy's `ILog` and the test logs that implement the vtable. Do not touch `console.@"error"` or a `LogLevel` value. Run `bun run tev`; it must pass.

5. **Documentation.** In Ziggy's `docs/user-guide/logging.md`, change the "Logging a line" table and example from `@"error"(message)` to `err(message)` and add one sentence saying it matches `std.log.err`. Update any other doc in Ziggy, the examples or Photosphere that shows `log.@"error"` (`grep -rn '@"error"' docs`).

## Unit Tests
- The existing `log.test.zig`, `file-log.test.zig` and worker log tests call `err` in place of `@"error"` and still pass: an `err` line reaches the console's standard error, the log file and the error log file, and a worker's `err` line reaches the main thread tagged with the worker.
- Photosphere's existing tests that check error lines pass unchanged apart from the call name.

## Smoke Tests
- Ziggy's `26-log-files` (the failing task's error line in both files) and every other Ziggy smoke test.
- Photosphere's `test:cli:zig`, `test:ziggy` and `test:ziggy:and` through `bun run tev`.

## Verify
- `grep -rn 'log\.@"error"(' ` finds nothing in Ziggy, the examples or Photosphere outside `docs/plans`.
- Ziggy `bun run test:everything` passes.
- Both examples' `bun run test:everything` pass.
- Photosphere `bun run tev` passes.

## Notes
- Only the `ILog` function and its vtable field are renamed. `LogLevel.@"error"` stays because it is the level's name on the wire (`window.ziggy.log("error", ...)` and the worker messages), and `console.@"error"` stays because it mirrors JavaScript's `console.error` and is a separate API.
- No new function is added, so no new unit test is needed; the existing tests of the error line cover the renamed one.
- The counts in steps 2 and 4 were taken from the shared-logging worktrees when the plan was written.
