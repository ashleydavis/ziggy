# One logging system in Ziggy for every app

## Overview

Ziggy already owns the log interface (`ILog`), the console log and the per-thread log (`setLog` / `currentLog` in `packages/ziggy/core/src/lib/task-queue/utils/log.zig`), and a worker's log lines already reach the main thread (`thread-log.zig`, `worker_pool.writeLog`). The file logging does not live in Ziggy. Photosphere has two separate file loggers, one in its CLI (`apps/cli-zig/src/lib/log.zig` and `apps/cli-zig/src/lib/file-logger.zig`) and one in its app (`packages-zig/photosphere-core/src/lib/file-logger.zig`). They differ in setup, options, file location, line format, what the console shows, whether worker lines reach the file and what happens when a write fails. This plan moves file logging and the console options into Ziggy as one system, so every program built on Ziggy (a Ziggy app, or a plain Zig program that uses Ziggy's task queue, such as Photosphere's CLI) logs the same way and is configured the same way. Each program names its own files through its configuration, so the log files of different programs stay different at a glance (Photosphere's CLI keeps `psi-<time>.log`, its app keeps `photosphere-<time>.log`). Ziggy gets a user guide page on how logging works, how to configure it and how to use it. Backward compatibility is not required.

## Issues

## Steps

1. **Write the documentation.** Create `docs/user-guide/logging.md`, describing the system as it is intended to work, so the human can review it before any code changes:
   - How code logs: `ziggy.task_queue.utils.log.log` and its functions (info, verbose, error, exception, warn, debug, tool, event), and that each line goes to the calling thread's log.
   - Threads: the main thread writes the console and the files; a worker's lines are sent to the main thread and written there, tagged with their source.
   - The console: which levels go to stdout and which to stderr, and that verbose, debug and tool lines appear only when their option is on.
   - The files: one log file with every level and one error file with errors, exceptions and warnings; the header (title, start time, command line when given, system information, the program's version and any extra header lines the program gives); the footer; the line format `[time] [LEVEL] [source] message`; one pair of files per run, named `<file prefix>-<start time>.log` and `<file prefix>-<start time>-errors.log`; nothing is rotated or deleted.
   - Configuration: every field of the file log configuration (step 3) and what it does, the helper that gives the default logs directory, and how a program lets an environment variable choose the directory.
   - Usage: starting the file log in a Ziggy app's `on_create` and closing it in `on_destroy`; starting it in a plain Zig program's `main` and closing it at exit; a worker needs nothing.
   - Failures: a failed write is reported on stderr and never stops the program; when the run ends and the error file has entries, its path is printed.
   - Logging from the frontend: `window.ziggy.log(level, message)` (step 7).
   - Reading the log back: `readLogDetails` (path and header), for bug reports.
   - Add the page to the list in `docs/user-guide.md`, and add "log file" and "error log file" to `docs/glossary.md` if the glossary does not already cover them.
   - STOP when the draft is written. Do not continue to step 2. Wait for the human to review and approve the documentation. If the human revises it, revise the remaining steps to match before continuing.

2. **Give the console log its options.** In `packages/ziggy/core/src/lib/task-queue/utils/log.zig`, change `ConsoleLog` to hold `verbose_enabled`, `debug_enabled` and `tools_enabled`, each with a `//` comment:
   - `verbose` writes to stdout when `verbose_enabled`; `debug` writes to the stream the approved documentation names when `debug_enabled`; `tool` writes `== <tool> stdout ==` and `== <tool> stderr ==` blocks to stdout when `tools_enabled`. Today `verbose` and `tool` do nothing and `debug` always writes.
   - Keep the default console log (the one `currentLog` falls back to) with every option off.
   - Run `mise exec -- zig build test --summary all`. It must pass.

3. **Add the file log.** Create `packages/ziggy/core/src/lib/task-queue/utils/file-log.zig` and export it from `packages/ziggy/core/src/lib/task-queue/utils.zig` as `file_log`. It lives beside `log.zig` so a program that is not a Ziggy app (one that uses only the task queue) can use it.
   - `IFileLogConfig`, each field with a `//` comment: `file_prefix` (the start of both file names), `title` (the first line of the header, the error file's title adds "Error"), `logs_dir` (the directory the files go in), `command` (`?[]const u8`, the command line written into the header, null to leave the line out), `version` (the program's version), `header_lines` (`[]const []const u8`, extra lines the program adds to the header, such as tool versions and a build commit), and the console options `verbose`, `debug` and `tools`.
   - `FileLog.start(allocator, io, config: IFileLogConfig) !*FileLog`: creates `logs_dir` if it is not there, writes both files with their headers, makes a `ConsoleLog` with the console options, and installs the file log as the calling thread's log with `setLog`. Port the header layout, the footer and the line format from Photosphere's app logger (`packages-zig/photosphere-core/src/lib/file-logger.zig` in https://github.com/ashleydavis/photosphere), which already writes the source tag.
   - The ILog functions write the line to the file (and errors, exceptions and warnings to the error file too), then pass the call to the console log. Verbose, debug and tool lines are always written to the file; the options decide only what the console shows.
   - `FileLog.logFrom(source: []const u8, message: IWorkerLogMessage)`: writes a line that came from somewhere else (a worker, the frontend) with its source tag.
   - `FileLog.close() !void`: writes the footers, stops accepting lines, prints `Errors, warnings, and exceptions were logged to: <path>` when the error file has entries, and returns the first write failure. `FileLog.stop()`: calls `close`, reports a failure on stderr, uninstalls the log with `setLog(null)` and frees the logger.
   - `FileLog.fromILog(log: ILog) ?*FileLog`, `getLogFilePath`, `getErrorLogFilePath`, `hasLoggedErrors`.
   - A failed write is reported on stderr with the file path and the error name. It is never ignored.
   - `defaultLogsDir(allocator, program_name) ![]const u8`: `<OS temporary directory>/<program_name>/logs`. Add the OS temporary directory lookup to `packages/ziggy/core/src/lib/task-queue/utils/` (TMPDIR on Linux and macOS, TEMP or TMP on Windows, the app's cache directory on Android and iOS as the approved documentation says), since Ziggy has none today.
   - `readLogDetails(allocator, io, log_file_path) !ILogDetails`: the path and the header (everything up to `--- Log Start ---`), ported from Photosphere's app logger.
   - Make `ILog.getLogDetails` of `FileLog` return `readLogDetails` of its own file.
   - Follow the thread rules in `CLAUDE.md`: the file log belongs to the thread that starts it, no other thread touches it, and it keeps no Io or allocator for anything but its own memory and files. If keeping the Io in the struct breaks the rule that system services are never stored in a struct, change the ILog functions that write to take the Io from the calling thread instead, and say so in the documentation.
   - Run `mise exec -- zig build test --summary all`. It must pass.

4. **Tag worker lines with their source.** In `packages/ziggy/core/src/lib/worker-pool.zig`, change `writeLog` so that when `FileLog.fromILog(currentLog())` gives a file log, the line is written with `logFrom` and the source `Worker <id>`, and otherwise goes to the console log as it does today, prefixed with the same source. Pass the worker id in from the caller of `writeLog`. Run the Zig tests.

5. **Pass the console options to workers.** Find where `QueueLog` gets `verbose_enabled` and `tools_enabled` (`thread-log.zig` and its caller in `worker-pool.zig`) and set them from the main thread's file log options when one is installed, so a worker sends exactly the lines the main thread will show or write. Since verbose and tool lines always go to the file, a worker must send them whenever a file log is installed. Run the Zig tests.

6. **Use it in the Ziggy template and the Ziggy test app.** In `apps/ziggy-template/backend/src/app.zig` and the test app's backend, start the file log in `on_create` with `file_prefix` and `title` named after the app, `logs_dir` from the app's own environment variable when it is set (`ZIGGY_TEMPLATE_LOG_DIR`, `ZIGGY_TEST_APP_LOG_DIR`) and `defaultLogsDir` otherwise, and stop it in `on_destroy`. Run `mise exec -- bun run test:smoke`.

7. **Log from the frontend.** Add `window.ziggy.log(level, message)` to `packages/ziggy/core/src/lib/ziggy-inject.js` as a system message `{ "kind": "system", "name": "log", "data": { "level", "message", "error" } }`, handle it in `packages/ziggy/core/src/lib/system-messages.zig` by calling `logFrom` with the source `Frontend` when a file log is installed and the console log otherwise, and add its type to `packages/ziggy/frontend`. A level that is not one of the eight is reported as a `core-error` system event. Run `mise exec -- bun run compile` and the Zig tests.

8. **Release Ziggy.** Once steps 2 to 7 pass `bun run test:everything`, a Ziggy version tag holding them is needed before the Photosphere steps. Follow `docs/development/releasing-ziggy.md`.

9. **Move Photosphere's app to Ziggy's file log.** In the Photosphere repository, move to the new Ziggy tag as its `docs/photosphere-on-ziggy.md` says. Then:
   - In `packages-zig/photosphere-core/src/lib/main-state.zig`, replace `startFileLogger` with `FileLog.start`, with `file_prefix = "photosphere"`, `title = "Photosphere Desktop Log"`, `logs_dir` from `PHOTOSPHERE_LOG_DIR` or `defaultLogsDir(allocator, "photosphere")`, `command = null`, `version = config.version` and the tool versions as `header_lines`. Stop it where the logger is destroyed today.
   - Delete `packages-zig/photosphere-core/src/lib/file-logger.zig` and its test, keeping `fps-measurement` working by moving `appendToFile` into `logging.zig` or using Ziggy's.
   - Replace the `renderer-log` handler in `packages-zig/photosphere-core/src/lib/logging.zig` and its callers in the shared UI with `window.ziggy.log`, and back `get-log-details` with `readLogDetails`.
   - Run Photosphere's `bun run tev`.

10. **Move Photosphere's CLI to Ziggy's file log.** In the Photosphere repository:
    - Change `configureLog` in `apps/cli-zig/src/lib/log.zig` to call `FileLog.start` with `file_prefix = "psi"`, `title = "Photosphere CLI Log"`, `logs_dir` from `defaultLogsDir` under the process temporary directory (`getProcessTmpDir`, so smoke tests stay isolated per test), `command` the user's arguments, `version` and the build metadata and tool versions as `header_lines`, and the `--verbose`, `--debug` and `--tools` options. When `disableFileLogging` is set, install a `ConsoleLog` with those options instead.
    - Close the file log from the existing termination callback.
    - Delete the CLI's own `Log` struct and `apps/cli-zig/src/lib/file-logger.zig` and their tests, and change `getFileLogger` callers (`cmd/add.zig`, `cmd/check.zig`, `cmd/bug.zig`) to use `FileLog.fromILog`.
    - In `apps/cli-zig/src/lib/worker-pool.zig`, replace `writeWorkerLog` with Ziggy's `worker_pool.writeLog`, so CLI worker lines reach the file.
    - Delete the unused `packages-zig/utils-zig/src/lib/log.zig` and `packages-zig/utils-zig/src/test/log.test.zig`.
    - Run Photosphere's `bun run tev`.

11. **Update the documentation.** Bring `docs/user-guide/logging.md` in line with what was built: every configuration field, the default directory per platform, the console streams, the line format and the failure handling. Update `docs/development/architecture.md` where it describes worker messages, and Photosphere's docs that describe its log files.

## Unit Tests

In `packages/ziggy/core/src/test/` (task-queue utils tests go under `packages/ziggy/core/src/test/task-queue/`):

- `ConsoleLog`: each of verbose, debug and tool writes only when its option is on (capture with `console.setCapture`).
- `FileLog.start`: creates `logs_dir`, writes both files named `<file_prefix>-<time>.log` and `<file_prefix>-<time>-errors.log`, the header holds the title, the command line only when given, the version and every `header_lines` entry, and the calling thread's log is the file log.
- Each ILog function of `FileLog`: the line in the log file has the right level and format; error, exception and warn also reach the error file; verbose, debug and tool reach the file with their console options off.
- `FileLog.logFrom`: the line carries the source tag.
- `FileLog.close`: writes the footer; the error footer only when there were errors; prints the error file path only then; a second call does nothing; a write failure (the file removed and its directory made read-only, or the path made a directory) is returned.
- `FileLog.stop`: uninstalls the log.
- A failed write during logging is reported on stderr.
- `FileLog.fromILog`: gives the logger for its own ILog and null for a console log.
- `defaultLogsDir`: ends in `<program_name>/logs` under the temporary directory the environment names.
- `readLogDetails`: gives the header up to `--- Log Start ---`.
- `worker_pool.writeLog`: with a file log installed, a worker line lands in the file tagged `Worker <id>`.
- The `log` system message: writes a `Frontend` line; an unknown level gives a `core-error` event.
- Photosphere: update the tests of `configureLog`, `main-state.zig` startup and `logging.zig` to the new calls, and delete the tests of the deleted file loggers.

## Smoke Tests

- Ziggy: a new desktop and native scenario under `smoke-tests/` that starts the test app with `ZIGGY_TEST_APP_LOG_DIR` set to a directory from `ziggy_test_temp_dir`, queues a task whose handler logs an info and an error line, sends `window.ziggy.log("info", ...)` from the frontend, quits, and checks: one log file and one error file named with the test app's prefix; the worker lines tagged `Worker`; the frontend line tagged `Frontend`; the error line in the error file; both footers present.
- Photosphere app: extend an existing Photosphere App smoke scenario that already sets `PHOTOSPHERE_LOG_DIR` (or add the variable to one) to check the `photosphere-*.log` file has a worker-tagged line.
- Photosphere CLI: extend a Zig CLI smoke test to check a `psi-*.log` file exists under the test's temporary directory and holds a line written by a worker.

## Verify

- `mise exec -- zig build` and `mise exec -- bun run compile` pass in Ziggy.
- `mise exec -- bun run test:everything` passes in Ziggy, including the new smoke scenario.
- In Photosphere, `mise exec -- bun run compile` passes and `mise exec -- bun run tev` passes.
- `grep -rn "file-logger" apps/cli-zig packages-zig` in Photosphere finds nothing.
- Running the Ziggy test app and the Photosphere CLI each produce files with their own prefix, in their own directory.

## Notes

- Ziggy's code never names the app, so everything app-specific (file prefix, title, directory variable, tool versions, build commit) comes in through `IFileLogConfig`.
- The file log is started by the program, not by a field of `ziggy.core.App`, because Photosphere's CLI is not a Ziggy app and both must be set up the same way. An `App` field would also have to run before `on_create`, while Photosphere's header needs media tools that `on_create` makes.
- Photosphere's two loggers disagree on where debug lines go on the console (CLI: stderr, Ziggy's console log: stdout). Step 1's documentation picks one for the human to approve.
- The CLI keeps writing under the process temporary directory so its smoke tests keep a log directory per test. The app keeps `PHOTOSPHERE_LOG_DIR`. Both are chosen by the program, through `logs_dir`.
- On Windows the app has no console, and on Android and iOS nothing routes stderr to the system log, so console output (including write failures) is seen only by a developer running from a terminal. Routing it to logcat and the iOS system log is out of scope.
- Steps 9 and 10 are in the Photosphere repository and depend on the release in step 8.
