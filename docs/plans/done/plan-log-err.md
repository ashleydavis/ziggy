# Rename `log.@"error"` to `log.err`

## Overview
`error` is a reserved word in Zig, so the log's error function has to be called as `log.@"error"(...)`. Zig's own standard library names the same thing `std.log.err`. This plan renames the `ILog` function and its vtable field to `err`, so callers write `log.err("...")`, and updates every caller in Ziggy, the two examples and Photosphere. Backward compatibility is not required, so the old name is removed rather than kept beside the new one.

## Issues

## Steps

- [x] 1. **Rename in Ziggy's log.** In `packages/ziggy/core/src/lib/task-queue/utils/log.zig`, rename the vtable field `@"error"` (line 57) to `err` and the `ILog` method `pub fn @"error"` (line 98) to `pub fn err`, and update every vtable that sets the field (`.@"error" = logError` and the others in `log.zig`, `file-log.zig`, the worker's `QueueLog` and any test log the compiler names). Leave `LogLevel.@"error"` and `console.@"error"` as they are (see Notes). Update the doc comments that name the function. Run `zig build test --summary all` in the Ziggy worktree; it must pass.

   **Summary:** The log lives at `packages/ziggy/log/src/lib/log.zig`, not the path above. Renamed the `VTable` field and `ILog` method to `err` and updated the vtables in `log.zig`, `file-log.zig`, `memory-log.zig`, `mute-log.zig`, `core/src/lib/thread-log.zig`, `log.test.zig` and the two test logs in `worker-pool.test.zig`. `ILog.exception`'s parameter `err` shadowed the new method (compile error), so it is now `cause`. No doc comment named the function. `zig build test --summary all` exit 0 (60/60, 16/16 and 834/836 with 2 skipped), saved in `tmp/evidence/compile`.

- [x] 2. **Update Ziggy's callers.** Replace every `log.@"error"(` and `.@"error"(` call on an `ILog` or on `utils.log.log` in `packages/` and `apps/` (8 files in `packages/`, 1 in `apps/`, found with `grep -rn 'log\.@"error"(' packages apps`) with `.err(`. Run `zig build test --summary all` and `bun run test:everything`; both must pass.

   **Summary:** Renamed the calls in `core.zig` (6), `worker-pool.zig` (4), `exec.zig`, `system-messages/config.zig`, `log.test.zig`, `file-log.test.zig`, `memory-log.test.zig` and `apps/ziggy-test-app/backend/src/lib/handlers.zig`. The `.@"error" =` struct fields of JSON messages and `LogLevel.@"error"` are unchanged. `zig build test --summary all` exit 0. `bun run test:everything` exit 0 (compile, test, compile-zig, test-zig and smoke; 36 smoke tests passed, including `26-log-files`). Ziggy's test set has no Android target, so `test:zig:android` (60/60) and `test:smoke:android` (20/20, including `26-log-files`) were run too, both exit 0. Saved in `tmp/evidence/`.

- [x] 3. **Update the examples.** In both example worktrees, replace any `log.@"error"(` with `log.err(` (none are there today; check with grep). Run each example's `bun run test:everything`.

   **Summary:** grep found no `@"error"` in either example. Decision: both examples pin Ziggy v0.0.25, so to make the run test the rename, each worktree's `build.zig.zon` points its `ziggy` dependency at the Ziggy worktree (`.path = "../../../../ziggy/.claude/worktrees/log-err"`). This is a temporary local-Ziggy switch and goes back to a release tag when Ziggy is released. `bun run test:everything` exit 0 in both (compile, test, compile-zig, test-zig and smoke, 4 smoke tests passed), saved in each worktree's `tmp/evidence/tests`.

- [x] 4. **Update Photosphere's callers.** In the Photosphere worktree, replace every `log.@"error"(` call on the log (38 uses in 27 files under `packages-zig`, 98 uses in 27 files under `apps`) with `log.err(`, including any local log interface that wraps Ziggy's `ILog` and the test logs that implement the vtable. Do not touch `console.@"error"` or a `LogLevel` value. Run `bun run tev`; it must pass.

   **Summary:** Renamed 149 `log.@"error"(` calls in 42 files plus `ilog().@"error"(`, `quiet.@"error"(` and `consoleLogger.@"error"(`, and the `.@"error" =` field in every test log and in both file loggers (`photosphere-core/src/lib/file-logger.zig`, `apps/cli-zig/src/lib/file-logger.zig`): 59 files in all. The CLI's `FileLogger` wraps `ILog` and had its own `@"error"` method, now `err`. Its `exception` and `exceptionErased` parameter `err` shadowed it, so that parameter is now `cause`. `Command.@"error"` (commander's API), `console.@"error"` and the JSON `@"error"` fields are unchanged. Decision: Photosphere pins Ziggy v0.0.25, so `build.zig.zon` points `ziggy` at the Ziggy worktree (`.path = "../../../../ziggy/.claude/worktrees/log-err"`). This is a temporary local-Ziggy switch, with no CI or doc change, and goes back to a release tag when Ziggy is released. Graft (`~/projects/git-client/playbook/project`), named by the human, got the same change: 4 calls in `backend/src/lib/git-log.zig` and `git-diff-tree.zig`, with its `build.zig.zon` pointed at the Ziggy worktree. Its `test:zig` passed 107/107 and `test:smoke` passed 20/20. Photosphere `zig build test` exit 0 (4299/4305, 6 skipped). `bun run tev` exit 0: compile, test, test:cli:zig, test:ziggy, test:ziggy:and and test:zig all PASS. Saved in `tmp/evidence/`.

- [x] 5. **Documentation.** In Ziggy's `docs/user-guide/logging.md`, change the "Logging a line" table and example from `@"error"(message)` to `err(message)` and add one sentence saying it matches `std.log.err`. Update any other doc in Ziggy, the examples or Photosphere that shows `log.@"error"` (`grep -rn '@"error"' docs`).

   **Summary:** `logging.md` had no "Logging a line" table naming the functions. Its list of `ILog` functions is the sentence after the example, so that sentence now names each function with `err(message)` and says `err` matches `std.log.err`. The example now calls `log.err`. Added a v0.0.26 line to `docs/upgrade-notes.md`, as Ziggy's rules require for a change apps must make. No doc in the examples, Photosphere or graft showed `log.@"error"`. The plan's grep for `log\.@"error"(` finds nothing outside `docs/plans` in Ziggy, the examples, Photosphere or graft.

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
