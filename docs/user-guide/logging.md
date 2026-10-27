# Logging

Terms are defined in the [glossary](../glossary.md).

Ziggy has one logging system for every program built on it: a Ziggy app's backend, or a plain Zig program that uses only Ziggy's task queue, such as a command line tool. Each program logs the same way and is configured the same way. Only its configuration differs, so each program's log files carry its own name.

## Logging a line

There is no global log. Code logs to the `ILog` (`ziggy.task_queue.utils.log.ILog`) it is given:

- A message handler, a menu item's function or an app function writes to `services.log`, the main thread's log on its handler services.
- A task's handler writes to `services.log` on its task services, the worker's log. A task queue handler reads the same log from its context, `context.log`.
- Any other function that logs takes the log as an argument, `log: ILog`, after its `std.Io` when it has one, and its caller passes its own down.

```zig
fn importPhotos(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, request: ImportRequest) !void {
    const log = services.log;
    log.info("Imported 12 photos");
    log.warn("The thumbnail is missing");
    try readThumbnail(io, log, request.path);
}

fn readThumbnail(io: std.Io, log: ziggy.task_queue.utils.log.ILog, path: []const u8) !void {
    readFile(io, path) catch |err| {
        log.exception("Could not read the file", err);
        return err;
    };
}
```

There is no function that gives a log. Code that has been given no log, such as a test, `main` before it has made its log or a thread of a program's own, makes a `ziggy.task_queue.utils.log.ConsoleLog` where it starts (`var console_log: ConsoleLog = .{};`, every option off unless it sets one) and passes `console_log.ilog()` down.

| Function | What it logs |
|---|---|
| `info(message)` | An informational line. |
| `verbose(message)` | Detail that is not needed day to day. |
| `@"error"(message)` | An error. |
| `exception(message, err)` | An error with the chain of errors that caused it. |
| `warn(message)` | A warning. |
| `debug(message)` | Detail for whoever is debugging the program. |
| `tool(tool_name, .{ .stdout = ..., .stderr = ... })` | What an external tool wrote. |
| `event(message)` | Something that happened, such as a task starting. |

`log.verboseEnabled()` says whether verbose lines are shown on the console, so a caller can skip building an expensive verbose line.

## Where a line goes

A line goes to the log it is written to, and each thread has a log of its own to hand down:

- **The main thread's log** is `services.log` on the handler services. It is set once, before the handler services are made, and does not change: for an app with a name it is the app's file log, which writes the console and the log files, and otherwise it is the console log.
- **A worker's log** is `services.log` on its task services. It sends each line to the main thread as a message, and the main thread writes it to its own log, tagged with its source, `Worker <id>`. A task handler needs to do nothing for this.
- **The frontend** sends lines with `window.ziggy.log` (see [Logging from the frontend](#logging-from-the-frontend)), and the main thread writes them tagged `Frontend`.

Until a file log is its target, the main thread's log writes to the console log, with verbose, debug and tool lines off.

### The console

| Level | Stream | Shown |
|---|---|---|
| info | stdout | Always. |
| verbose | stdout | Only when `verbose` is on. |
| error | stderr | Always. |
| exception | stderr | Always: the message, then the error chain on the lines after it. |
| warn | stderr | Always. |
| debug | stderr | Only when `debug` is on. |
| tool | stdout | Only when `tools` is on: `== <tool> stdout ==` and `== <tool> stderr ==`, each followed by what the tool wrote. |
| event | stdout | Always, as `[EVENT] <message>`. |

A line from a worker or the frontend is prefixed with its source in brackets, such as `[Worker 2] Imported 12 photos` or `[Worker 2] [EVENT] Task started`.

On Windows a desktop app has no console, and on Android and iOS nothing shows stdout or stderr, so there the console is seen only by a developer running the app from a terminal. The log files are what a user can send.

### The log files

A file log writes two files for each run of the program, in the logs directory it is given:

- `<file prefix>-<start time>.log`: every line, at every level, whatever the console shows. Verbose, debug and tool lines always reach this file.
- `<file prefix>-<start time>-errors.log`: the error, exception and warning lines again, and nothing else.

The start time is in UTC, written as `2026-10-26T09-15-04` so it is a valid file name on every platform. Each run makes a new pair of files. Nothing is rotated or deleted.

Each line is:

```
[2026-10-26T09:15:04.123Z] [INFO] Imported 12 photos
[2026-10-26T09:15:04.456Z] [ERROR] [Worker 2] Could not read the file
```

The time is in UTC, the level is in capitals and the source is left out for a line the main thread logged itself. An exception's line holds the message and then, on the lines after it, the error chain, written whole however long it is.

Both files start with a header:

```
================================================================================
My App Log
Started: 2026-10-26T09:15:04.000Z
Command: my-app import ./photos
Working Directory: /home/me
================================================================================

--- System Information ---
Platform: linux
Architecture: x64
OS Release: 6.8.0
Zig Version: 0.16.0
Version: 1.2.0

<the program's own header lines>

--- Log Start ---
```

- The first line is the configured title. The error file's is the title followed by ` (errors)`, and its header ends with `If this file contains nothing below, it means there were no errors.` and `--- Error Log Start ---` instead of `--- Log Start ---`.
- `Command:` is there only when the program gives a command line.
- The program's own header lines (tool versions, a build commit) follow the system information, in the order given. The program writes its own section headings among them.

When the file log is closed, the log file gets a footer with the time it ended and how long the run took, and the error file gets one if anything was written to it:

```

--- Log End ---
Completed: 2026-10-26T09:20:11.000Z
Duration: 307000ms (307.00s)
================================================================================
```

## Starting the file log

A Ziggy app's file log is started and stopped by Ziggy (see [In a Ziggy app](#in-a-ziggy-app)). Any other program starts the file log once, on its main thread, with `FileLog.start`, and stops it once at the end with `stop`. Starting it does not make it anyone's log: the program passes `logger.ilog()` down to the code that logs.

```zig
const file_log = ziggy.task_queue.utils.file_log;

const logger = try file_log.FileLog.start(allocator, io, .{
    .file_prefix = "my-app",
    .title = "My App Log",
    .logs_dir = logs_dir,
    .command = null,
    .version = "1.2.0",
    .header_lines = &.{},
    .verbose = false,
    .debug = false,
    .tools = false,
});
// ...
logger.stop(allocator, io);
```

`start` allocates the logger with the allocator it is given, and `stop` must be given the same one. Both run on the thread that logs to the files.

### In a Ziggy app

A Ziggy app writes no code to have log files. It gives its details in `app.zon`, beside its `build.zig`:

```zig
.{
    .name = "my-app",
    .title = "My App",
    .version = "1.2.0",
}
```

| Field | Required | What it is for |
|---|---|---|
| `name` | Yes | Names the log files: `my-app-<start time>.log` and `my-app-<start time>-errors.log`. |
| `title` | Yes | The first line of each file's header. |
| `version` | No | The header's `Version:` line. Without it the header has none. |

Ziggy's build reads `app.zon` with Zig's ZON parser when the app's `build.zig` calls `dependency`. A missing `app.zon`, one that does not parse, a missing required field or a field it does not know fails the build. The main thread starts the file log before it makes the handler services, so `services.log` is the file log for the whole run, and stops it after the `.after_tasks_stopped` call of `on_destroy`. The files go in the `logs` directory of the directory `<NAME>_LOG_DIR` names when that environment variable is set (the name in capitals with each dash as an underscore, such as `MY_APP_LOG_DIR`), or else in the `logs` directory of the app's data directory, which exists on every platform.

The app's first lines, its lines while it stops, its lines in `.after_tasks_stopped` and every task's lines are in the files. The app's code never holds the logger: on the main thread, `FileLog.fromILog(services.log)` finds it. A worker needs nothing: its lines reach the file log through the main thread. An app whose log files cannot be made does not start: creating the backend fails before `on_create` is called, and the native app reports the error.

To give a release its version in the log, the release build writes it into `app.zon`'s `.version` before building.

### In a plain Zig program

Start it in `main`, after handing the environment to `process_env.setEnvironMap` and reading the program's options, pass `logger.ilog()` to everything `main` calls that logs, and stop it on every way out of the program, including an exit after an error, so the footer is written.

### The configuration

| Field | Type | What it is for |
|---|---|---|
| `file_prefix` | `[]const u8` | The start of both file names, so each program's files can be told apart at a glance. |
| `title` | `[]const u8` | The first line of the log file's header. |
| `logs_dir` | `[]const u8` | The directory both files go in. It is created if it is not there. |
| `command` | `?[]const u8` | The command line written into the header as `Command:`, or null to leave the line out. |
| `version` | `?[]const u8` | The program's version, written into the header, or null for no `Version:` line. |
| `header_lines` | `[]const []const u8` | Extra lines for the header, such as the versions of the tools the program runs. |
| `verbose` | `bool` | Shows verbose lines on the console. |
| `debug` | `bool` | Shows debug lines on the console. |
| `tools` | `bool` | Shows the output of tools on the console. |

The three console options change only the console. The log file always gets every line.

### Choosing the logs directory

A Ziggy app uses its data directory (above). For a plain Zig program, `file_log.defaultLogsDir(allocator, program_name)` gives `<temporary directory>/<program_name>/logs`, with the temporary directory read from the calling thread's environment by `temp_dir.osTmpDir`:

- Linux and macOS: `TMPDIR`, `TMP` or `TEMP`, the first that is set and not empty, else `/tmp`.
- Windows: `TEMP` or `TMP`, else `%SystemRoot%\temp` (or `%windir%\temp`). With none of them set it fails with `NoTemporaryDirectory`.

To let a user or a test choose the directory, read an environment variable of the program's own with `process_env.getEnv` and fall back to `defaultLogsDir`. A test that runs beside other tests gives each run a directory of its own this way.

## When a write fails

A log line that cannot be written to its file is reported on stderr, as `Could not write to the log file <path>: <error>`, and the line still goes to the console: logging never stops what is being logged. `stop(allocator, io)` reports a failure to write the footers the same way. `close(io)` writes the footers and stops writing to the files without freeing the logger, and returns the first failure instead of reporting it. After `close`, lines still reach the console.

When the file log is closed and anything was written to the error file, it prints:

```
Errors, warnings and exceptions were logged to: <path of the error file>
```

## Logging from the frontend

The frontend writes to the backend's log with `window.ziggy.log`:

```typescript
window.ziggy.log("info", "The gallery opened");
window.ziggy.log("exception", "Could not load the page", error.stack);
window.ziggy.log("tool", "ffprobe", undefined, { stdout: probeOutput });
```

- The level is one of `info`, `verbose`, `error`, `exception`, `warn`, `debug`, `tool` and `event`. Any other level is reported as a `core-error` system event naming `UnknownLogLevel`.
- The third argument, for `exception`, is the text of the error.
- The fourth argument, for `tool`, is what the tool wrote (`stdout` and `stderr`), and the message is the tool's name.
- The line is written by the main thread, tagged `Frontend`.

## Reading the log back

`file_log.readLogDetails(allocator, io, log_file_path)` gives the path of a log file and its header (everything up to `--- Log Start ---`), as `ILogDetails`, for a bug report. `log.getLogDetails(allocator, io)` on a log gives the same for a file log, and a null path for the console log; on `services.log` it is the main thread's file log's. It reads the file, so call it from a task when the frontend is waiting.

The logger also gives `getLogFilePath()`, `getErrorLogFilePath()` and `hasLoggedErrors()`, and `FileLog.fromILog(services.log)` gives the main thread's file log, or null when there is none.

## Writing lines that came from elsewhere

A program with a worker pool of its own, or anything else that receives log lines from another thread, writes them on the main thread with `worker_pool.writeTaggedLine(arena, log, source, line)`, where `log` is the log to write them to (for the main thread's, `services.log`) and `line` is a `log.ILogLine` (level, message, error text, tool output). It writes the line through the log's ordinary functions with `[source] ` in front of it, and an exception becomes one error line with its error text under it. Ziggy's own worker pool writes its workers' lines this way, with the source `Worker <id>`, and starts its workers sending verbose and tool lines whenever the main thread's log writes a file (`log.logFilePath()` is not null), since the file always takes them.

## Key files

| File | What it holds |
|---|---|
| `packages/ziggy/core/src/lib/task-queue/utils/log.zig` | The `ILog` interface and the console log. |
| `packages/ziggy/core/src/lib/task-queue/utils/file-log.zig` | The file log, `defaultLogsDir` and `readLogDetails`. |
| `packages/ziggy/core/src/lib/task-queue/utils/temp-dir.zig` | `osTmpDir`, the operating system's temporary directory. |
| `packages/ziggy/core/src/lib/thread-log.zig` | A worker's log, which sends its lines to the main thread. |
| `packages/ziggy/core/src/lib/worker-pool.zig` | `writeLog`, which writes a worker's line to the main thread's log. |
| `packages/ziggy/core/src/lib/system-messages/log.zig` | The `log` system message `window.ziggy.log` sends. |
| `packages/ziggy/core/src/lib/ziggy-inject.js` | `window.ziggy.log`. |
