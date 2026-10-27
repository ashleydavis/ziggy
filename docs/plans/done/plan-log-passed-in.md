# Pass the log in instead of reaching a global

## Overview

Ziggy's log is reached through a global: `ziggy.task_queue.utils.log.log`, a constant whose functions pass each call on to the calling thread's log, kept in the thread local `thread_log` and changed with `setLog` and read with `currentLog`. Photosphere reaches it the same way, through `utils-zig`, in 213 places in 118 files. A global cannot be swapped for one test without touching every other user, and the per-thread switching hides which log a function writes to. This plan removes the global log, `thread_log`, `setLog` and `currentLog`: every function that logs is given the log, as an `ILog` argument, or reads it from the services it is already given (`services.log` on the handler services and the task services). Each thread still has its own implementation: the main thread's writes the console and the log files, and a worker's sends each line to the main thread, which writes it. The change covers Ziggy (core, task queue, the template, the test app), the two Ziggy examples and Photosphere (app core, CLI and `packages-zig`), so nothing is left on the old API. Backward compatibility is not required.

## Issues

## Steps

All work is done in the `shared-logging` worktrees: Ziggy at `ziggy/.claude/worktrees/shared-logging`, Photosphere at `photosphere/.claude/worktrees/shared-logging`, and the examples at `ziggy-example-vite/.claude/worktrees/shared-logging` and `ziggy-example-rsbuild/.claude/worktrees/shared-logging`, each of which takes Ziggy from its `../ziggy`, which `.claude/worktrees/ziggy` links to the Ziggy worktree. Run every command through `mise exec --`.

1. **Remove the global log from Ziggy's log module.** In `packages/ziggy/core/src/lib/task-queue/utils/log.zig`:
   - Delete `pub const log`, `ThreadLog`, `threadlocal var thread_log`, `setLog` and `currentLog`.
   - Keep `ILog`, `ILogDetails`, `noLogDetails`, `IToolOutput`, `LogLevel`, `ILogLine` and `ConsoleLog`. Keep the immutable constant `console_log` (every option off), and add `pub fn defaultConsoleLog() ILog`, which returns the ILog of that constant, for a caller that has been given no log, such as a test.
   - Update `packages/ziggy/core/src/test/task-queue/log.test.zig`: the tests of `setLog`, of a log set on one thread not being another's, and of the default log are replaced by tests that call a `ConsoleLog`'s ILog directly and `defaultConsoleLog()`.
   - Nothing else compiles yet; steps 2 to 7 bring it back. Run `zig build test --summary all` at the end of step 7.
   - [x] Done. `log`, `ThreadLog`, `thread_log`, `setLog` and `currentLog` are gone from `log.zig`; `defaultConsoleLog()` returns the ILog of the `console_log` constant. `log.test.zig` tests a `ConsoleLog`'s ILog and `defaultConsoleLog()` directly.

2. **Give the handler services the main thread's log.** In `packages/ziggy/core/src/lib/services.zig`, add to `HandlerServices` the field `log: ILog` (with its `//` comment: the main thread's log, which a handler, a menu item's function or an app function writes to) and the function `useLog(self, io, allocator, log: ?ILog) ?ILog`, which makes the given log the main thread's log (null for the console log) and returns the one that was in use before.
   - In `packages/ziggy/core/src/lib/core.zig`, add a `MainLog` struct to the main thread's state (a local of the main thread's run, never a global): an ILog whose functions pass each call to its current target, which starts as `defaultConsoleLog()`. `MainServices` sets `HandlerServices.log` to the `MainLog`'s ILog, and its `useLog` sets the target and returns the previous one. `useLog(null)` returns the target to the console log.
   - Add `pub fn targetOf(log: ILog) ILog` to `MainLog`, which gives the log a `MainLog` passes to (or the log itself when it is not a `MainLog`), so `FileLog.fromILog(MainLog.targetOf(services.log))` finds the app's file log.
   - Everything in `core.zig` that logged through the global passes `services.log` or the `MainLog`'s ILog instead.
   - The fake native app (`fake-native-app.zig`) and every test that builds a `HandlerServices` set `log`.
   - [x] Done. `HandlerServices` has `log` and `useLog(io, allocator, log)`. `MainLog` (in `core.zig`, part of the main thread's run) forwards to its target, which starts as `defaultConsoleLog()`; `useLog` returns the previous target, or null when it was the console log. `MainLog.targetOf` gives the target. The fake native app and the tests that build services set `log`. Tested in `app-log.test.zig` (useLog, targetOf) and `file-log.test.zig`.

3. **Give the task services the worker's log.** In `packages/ziggy/core/src/lib/task-runner.zig`, add to `TaskServices` the field `log: ILog` (the worker's log, which sends each line to the main thread). In `packages/ziggy/core/src/lib/worker.zig`, the worker passes its `QueueLog`'s ILog into every `TaskServices` it makes (`task-runner.zig` lines that build `.{ .task = ... }`). `QueueLog.set` no longer calls `setLog`: it only sets the console forward, and `QueueLog.unset` only clears it. `task-runner.zig`'s own log call (the task event failure) and `worker.zig`'s (the task completion callback) use the worker's log.
   - [x] Done. `TaskServices.log` is the worker's `QueueLog`, made before the worker's runtime. `QueueLog.set` and `unset` only change the console forward. Decision: `ITaskContext` (the task queue's handler context) and `TaskContext.init` also gained `log`, since task queue handlers have no task services; a handler reads `context.log`.

4. **Pass the log through the worker pool and the task queue.** In `packages/ziggy/core/src/lib/worker-pool.zig`, delete `const log = &utils.log.log` and give every function that logs a `log: ILog` argument, passed by its caller from the main thread's log: `writeLog(arena, log, source, text)`, the worker message handling, `createWorker` (which reads `FileLog.fromILog(MainLog.targetOf(log))` for whether to send verbose and tool lines) and the callback error paths. In `packages/ziggy/core/src/lib/task-queue/task-queue.zig`, delete its `const log` and give the functions that log (task tracking and the completion and event callbacks) a `log: ILog` argument from their callers.
   - [x] Done. Every worker pool function that logs takes `log`; `createWorker` reads `FileLog.fromILog(MainLog.targetOf(log))`; `writeLog(arena, log, source, text)`. In the task queue, `addTask`, `awaitAllTasks`, `awaitTask`, `shutdown` and `deinit` take a log, and so do the backend's `addTask`, `cancelTasks` and `waitForMessage`. Decision: the completion, event and task-added callback types take the log as an argument, so a callback logs to the log of whoever calls it.

5. **Pass the log into `exec`.** In `packages/ziggy/core/src/lib/task-queue/utils/exec.zig`, the functions that log (the command run and its failure and tool output) take `log: ILog`. Update their callers and `packages/ziggy/core/src/test/task-queue/exec.test.zig`.
   - [x] Done. `execLogged(allocator, io, log, ...)`; `exec.test.zig` has a test that the lines reach the log given.

6. **Stop the file log installing itself.** In `packages/ziggy/core/src/lib/task-queue/utils/file-log.zig`:
   - `FileLog.start` no longer calls `setLog`; it returns the log, and the caller installs it (for an app built with a name, `startFileLog` in `core.zig` makes it the `MainLog`'s target before `on_create` and returns the target to the console log before stopping it; a plain program passes `logger.ilog()` down).
   - `FileLog.stop` no longer calls `setLog(null)`.
   - `writeFrom(arena, log, source, line)` takes the log to write to instead of reading the calling thread's.
   - `packages/ziggy/core/src/lib/system-messages/log.zig` and `runSystem` in `core.zig` pass the main thread's log to `writeFrom`.
   - Update `file-log.test.zig`: the tests pass the file log's ILog where they used the global, and the test of `stop` uninstalling becomes a test that `useLog` returns the file log for `stop`.
   - [x] Done. `FileLog.start` no longer installs the log and `stop` no longer uninstalls it; `startFileLog` makes the file log the `MainLog`'s target before `on_create` and calls `useLog(null)` before stopping it. `writeFrom(arena, log, source, line)`; the `log` system message passes `MainLog.targetOf(services.log)`. `file-log.test.zig` has the `useLog` and stop test.

7. **Move the tests off the global.** Update every Ziggy test that called `setLog`, `currentLog` or the global log (`worker-pool.test.zig`, `log.test.zig`, `file-log.test.zig` and any other the compiler names) to build the log it needs and pass it, or to give it to the services it builds. Run `zig build test --summary all`; it must pass.
   - [x] Done. The worker pool, log, file log, app log, task queue and backend tests build the log they need and pass it. Decision: Ziggy's console gained `currentForward()` (with a test in `console.test.zig`) so code that forwards a thread's console lines for a while can put the previous forward back; Photosphere's ImageMagick runs use it (step 9). `zig build test`: core 560 passed (2 skipped), test app 54, template 10.

8. **The template, the test app and the examples.** None of them starts or stops a log: Ziggy does, from the name and version in their `build.zig.zon` (step 6). The hello world code (`apps/ziggy-template/backend/src/lib/hello-world.zig`) and the test app's handlers (`apps/ziggy-test-app/backend/src/lib/handlers.zig`) log through `services.log`. Make the same change in `backend/src/lib/hello-world.zig` of both example worktrees. Update the template, test app and example tests. Run `zig build test` in Ziggy and in each example, and `bun run compile` and `bun run test` in each.
   - [x] Done. The template's hello world, the test app's handlers and both examples' `hello-world.zig` log through `services.log`; their logging tests use `defaultConsoleLog()`. Both examples: `zig build test` (7 passed), `bun run compile`, `bun run test` (1 passed) and `test:everything` (compile-zig, test-zig, smoke) pass.

9. **Photosphere's packages.** In the Photosphere worktree, remove the re-export of the global (`packages-zig/utils-zig/src/index.zig` keeps exporting `log` for the types, which no longer hold a global). In each package below, delete every `const log = &utils.log.log` and every use of `utils.log.log` or `currentLog()`, and give each function that logs a `log: ILog` argument, passed by its caller. A task handler passes `services.log`, a message handler passes `services.log`, and a function the CLI calls is passed the CLI's log (step 11). Packages and their files that use the global today: `utils-zig` (4), `node-utils-zig` (4), `storage-zig` (6), `media-tools-zig` (4), `encryption-zig` (1), `api-zig` (1), `rest-api-zig` (1), `lan-share-network-zig` (1) and `node-api-zig` (37). Update each package's tests to pass a log; a test that captured log lines through `setLog` builds a log and passes it. Run `zig build test` after each package; it must pass.
   - [x] Done. Every `const log = &utils.log.log` is gone; functions that log take `log: ILog` after their Io, and callers pass theirs down. Decisions:
     - Structs that already held the Io of an iteration or callback (`DirectoryWalker`, `S3RangeReadableStream`, the file scanner's `DirectoryScan`, `SyncDatabaseState`, `RepairState`, `CheckPathsState`, prefetch's `MissingFilesIterator`, replicate's `CollectionDifferenceIterator` and `DatabaseDifferenceIterator`) hold the log beside it, because their callbacks and `next` take neither.
     - Retry operations' `run(self, io, log)` takes the log, and `retry`, `retryOrLog`, `tryOrLog` and `swallowError` pass it (`swallowError` writes nothing to it).
     - `IStorage.read`, `readStream` and the write lock functions take a log (encrypted reads log their decryption fallbacks); `IMediaSource.listPage`, `IImportScanner.scan`, `IAssetServerCore`'s functions, the HTTP router's handler type and termination callbacks take a log.
     - Task handlers read `context.log`; the auto import scanner's callbacks read their task context's log.
     - The HTTP server's threads and FFmpeg's log callback on a thread of no run use `defaultConsoleLog()`, as they did through the old per-thread default. ImageMagick's warning and error handlers (C callbacks with no context) print to the calling thread's console, which `runMagick` forwards to the log it was given for the length of the command (stdout as tool stderr, stderr as errors), so warnings still reach the run's log.
     - Thread entry functions in tests make their own console log.
     - Tests that installed a mock log pass it instead; fixtures (sandboxes, `ScannerTest`) own their muted log. The asset server routes test reads its connection thread's errors through the thread's console forward.

10. **Photosphere's app core.** In `packages-zig/photosphere-core` (14 files), `main-state.zig`'s `logFromMain` finds the file log Ziggy started through `FileLog.fromILog(MainLog.targetOf(services.log))`, and every function that logs takes `log: ILog` or reads `services.log`. `logging.zig`'s `get-log-details` finds the file log through `FileLog.fromILog(MainLog.targetOf(services.log))`. Update the core's tests (`test-support.zig`, `logging.test.zig`, `startup-and-shutdown.test.zig` and the rest the compiler names). Run `zig build test`.
   - [x] Done. `main-state.zig` has no `logFromMain` at HEAD (0 matches in the committed file) and looks up no file log, so that item had no code to change. `logging.zig`'s `get-log-details` finds the file log with `FileLog.fromILog(MainLog.targetOf(services.log))`. Timer callbacks read `handlerServicesOf(services).log`; the mobile planning bridge sets the task context's `log` from `services.log`; functions that log take `log` or read `services.log`. Tests use `services.log` and `services.useLog`; the startup test's check that "the thread that made the core keeps its own log" was removed with its subject, the per-thread log. Photosphere's `zig build test` passed (4433 passed, 6 skipped).

11. **Photosphere's CLI.** In `apps/cli-zig` (50 files), `configureLog` returns the `ILog` it made (the file log's, or the console log's when file logging is disabled) instead of installing it, `main` keeps it, and every command and library function that logs takes `log: ILog`, passed down from `main`. `writeWorkerLog` takes the log to write to and passes it to `ziggy.worker_pool.writeLog`, and `WorkerPoolBun.startWorker` reads `FileLog.fromILog(log)`. Update the CLI's tests (`log.test.zig`, `worker-pool-log.test.zig`, `cli-b-setup.test.zig`, `file-logger.test.zig`, `commands.test.zig` and the rest the compiler names). Run `zig build test` and `bun run test:cli:zig`.
   - [x] Done. `configureLog` returns the ILog; `main` keeps `var log` and `initContext` sets it through a pointer; commands take `log`. Decisions: encrypt, decrypt and bug make their own log with `configureLog`; `configureLog` writes the header's tool checks to the console log, since the file log does not exist yet. Progress callbacks with no other context (check, repair, compare, verify, replicate, consolidate, encrypt, decrypt, debug) are given a pointer to the log as their context; `ProgressState`, `ScanState`, the conflict resolver's context and `IMcpToolContext` hold the log. `writeWorkerLog` and `startWorker` take the log. `zig build test` and `bun run test:cli:zig` pass.

12. **Run everything.** Run Ziggy's `bun run test:everything`, each example's `zig build test`, `bun run compile`, `bun run test` and `bun run test:smoke`, and Photosphere's plain `bun run tev` (the Android pool is up, as the human said when the plan was written). All must pass.
   - [x] Done. Ziggy `bun run test:everything`: compile-zig, test-zig, smoke and smoke-dev passed. Both examples passed (step 8). Photosphere plain `bun run tev`: test:cli:zig, test:ziggy, test:ziggy:and and test:zig passed; the first run failed on the S3 integration suite, which is built only by `test-integration`, and passed once it was updated. Ziggy core also compiles for `x86_64-windows` and `aarch64-macos`. The grep for `setLog|currentLog|utils.log.log|thread_log` finds nothing in any repository (Photosphere's only match is a test's own `main_thread_logger`).

13. **Update the documentation.** In Ziggy's `docs/user-guide/logging.md`: replace "Logging a line" with logging through `services.log` in a handler or task and through a `log: ILog` argument elsewhere; replace the per-thread description with the main thread's log (`services.log`, changed with `services.useLog`) and a worker's (its `TaskServices.log`, which sends to the main thread); say Ziggy installs an app's file log as the target of `services.log`; document `defaultConsoleLog`, `MainLog.targetOf` and `writeFrom`'s log argument; say there is no global log. Update `docs/user-guide/app-declaration.md` (the handler services table gets `log` and `useLog`), `docs/user-guide/tasks.md` (the task services get `log`), and `docs/development/architecture.md` (how a worker's lines reach the main thread's log). In Photosphere, update `docs/photosphere-on-ziggy.md` where it describes logging.
   - [x] Done. Ziggy's `logging.md` (no global log, `services.log`, `useLog`, `MainLog.targetOf`, `defaultConsoleLog`, `writeFrom`'s log, file log no longer installs itself), `app-declaration.md` (`log` and `useLog` rows), `tasks.md` (`log` row) and `architecture.md` (how a worker's lines reach the main thread's log). Photosphere's `photosphere-on-ziggy.md` describes passing the log, the console log for C callbacks and server threads, and ImageMagick's forward.

## Unit Tests

- `ConsoleLog` called through its ILog, and `defaultConsoleLog()`, write what they did through the global (log.test.zig).
- `HandlerServices.log` writes to the console log until `useLog` is given a log; `useLog` returns the log in use before; `useLog(null)` returns to the console log.
- `MainLog.targetOf` gives the target of a `MainLog` and the log itself otherwise.
- `TaskServices.log` sends a line to the main thread, which writes it to the main thread's log tagged with the worker.
- `writeLog` and `writeFrom` write to the log they are given.
- `createWorker` sends verbose and tool lines when the main thread's log targets a file log.
- `exec`'s functions write to the log they are given.
- `FileLog.start` leaves the main thread's log as it was; `stop` does not touch it.
- The `log` system message writes to the main thread's log.
- Ziggy's main thread makes the file log of an app built with a name the target of `services.log` before `on_create`, and returns the target to the console log before stopping it (`app-log.test.zig`); the template's and the test app's handlers' lines reach the file.
- Each example's logging test.
- Photosphere: every function given a `log` argument keeps its existing tests, now passing a log, and each test that checked log output through `setLog` checks it through the log it passes. `configureLog` returns the file log, or the console log when file logging is disabled.

## Smoke Tests

- Ziggy: `26-log-files` (page, message handler and worker lines in the test app's files) on Linux and in dev mode, and the rest of Ziggy's smoke tests.
- Each example's `hello-world-app` smoke test.
- Photosphere: the CLI suite (`test:cli:zig`), the desktop app suite (`test:ziggy`) and the Android suite (`test:ziggy:and`).

## Verify

- Ziggy: `bun run test:everything` passes; `zig build test-binary-ziggy-core -Dtarget=x86_64-windows` and `-Dtarget=aarch64-macos` compile.
- `grep -rn "setLog\|currentLog\|utils.log.log\|thread_log" packages apps --include='*.zig'` in Ziggy, and the same over `packages-zig apps` in Photosphere and over each example's `backend`, find nothing outside comments.
- Each example: `zig build test`, `bun run compile`, `bun run test` and `bun run test:smoke` pass.
- Photosphere: the plain `bun run tev` passes, Android included.

## Notes

- Decisions the human made while the plan was written: the documentation is written last, with no review stop; handlers and tasks reach the log as the field `services.log`; Photosphere moves over in this plan; the Android pool will be up for the implementation.
- The console (`ziggy.task_queue.utils.console`, which the console log prints through and which forwards a worker's printed lines to the main thread) keeps its per-thread forward and test capture. Only the log was asked about.
- Ziggy's rules forbid storing a system service in a struct. `services.log` is a field of the services value that is passed to each handler, as the services' own functions are, and the `MainLog` lives in the main thread's state, which already holds the main thread's other state; no struct keeps a log of its own past a call.
- The plan uses `useLog` on the handler services to switch the main thread's log, because the field `services.log` is fixed when the services are made; the `MainLog` it points to is what changes.
- Photosphere's counts come from `grep` over `packages-zig` and `apps` at the time of writing; the compiler names any use the counts missed.
- No step commits, pushes, tags, releases or deletes a file with `rm`: every change stays uncommitted in the worktrees.
