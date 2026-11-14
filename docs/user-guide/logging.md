# Logging

Terms are defined in the [glossary](../glossary.md).

Ziggy's logging system.

## Logging a line

There is no global log. Code logs to the `ILog` (`ziggy.log.ILog`) it is given:

- A message handler, a menu item's function or an app function writes to `services.log`, the main thread's log on its handler services.
- A task's handler writes to `services.log` on its task services, the worker's log. A task queue handler is given the same log as its `log` argument.
- Any other function that logs takes the log as an argument, `log: ILog`, after its `std.Io` when it has one, and its caller passes its own down.

```zig
fn importPhotos(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, request: ImportRequest) !void {
    _ = timers;
    _ = allocator;
    const log = services.log;
    log.info("Imported 12 photos");
    log.warn("The thumbnail is missing");
    try readThumbnail(io, log, request.path);
}

fn readThumbnail(io: std.Io, log: ziggy.log.ILog, path: []const u8) !void {
    readFile(io, path) catch |err| {
        log.exception("Could not read the file", err);
        return err;
    };
}
```

Code that has been given no log, such as a test or a thread of a program's own, makes a `ziggy.log.ConsoleLog` where it starts (`var console_log: ConsoleLog = .{};`, every option off unless it sets one) and passes `console_log.ilog()` down.

`ILog` has a function for each kind of line. `log.verboseEnabled()` says whether verbose lines are shown on the console, so a caller can skip building an expensive verbose line.

## Where a line goes

A line goes to the log it is written to:

- **The main thread's log** is `services.log` on the handler services. It writes the console and the log files.
- **A worker's log** is `services.log` on its task services. Its lines are tagged `Worker <id>`.
- **The frontend** sends lines with `window.ziggy.log` (see [Logging from the frontend](#logging-from-the-frontend)), and the main thread writes them tagged `Frontend`.

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

A line from a worker or the frontend is prefixed with its source in brackets, such as `[Worker 2] Imported 12 photos` or `[EVENT] [Worker 2] Task started`.

On Windows a desktop app has no console, and on Android and iOS nothing shows stdout or stderr, so there the console is seen only by a developer running the app from a terminal. The log files are what a user can send.

### The log files

A file log writes two files for each run of the program, in the logs directory it is given:

- `<file prefix>-<start time>-<pid>.log`: every line, at every level, whatever the console shows.
- `<file prefix>-<start time>-<pid>-errors.log`: the error, exception and warning lines again.

The start time is in UTC, written as `2026-10-26T09-15-04` so it is a valid file name on every platform. The process id follows the start time, so each window of the app writes its own pair of files, including two windows started in the same second. Each run makes a new pair of files. Nothing is rotated or deleted.

Both files start with a header holding the title, start time, command line, working directory, system information, version and the program's own header lines.

When the file log is closed, each file ends with the time the run ended and how long it took.

## The file log in a Ziggy app

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
| `name` | Yes | Names the log files: `my-app-<start time>-<pid>.log` and `my-app-<start time>-<pid>-errors.log`. |
| `title` | Yes | The first line of each file's header. |
| `version` | No | The header's `Version:` line. Without it the header has none. |

A missing `app.zon`, one that does not parse, a missing required field or a field it does not know fails the build. `services.log` is the file log for the whole run. The files go in the `logs` directory of the directory `<NAME>_LOG_DIR` names when that environment variable is set (the name in capitals with each dash as an underscore, such as `MY_APP_LOG_DIR`), or else in the `logs` directory of the app's data directory, which exists on every platform.

Every line the app and its tasks write is in the files. On the main thread, `services.log.logFilePath()` gives the path of the log file. An app whose log files cannot be made does not start, and the native app reports the error.

To give a release its version in the log, the release build writes it into `app.zon`'s `.version` before building.

## The file log in a command line tool

A command line tool that uses Ziggy's task queue without the rest of Ziggy starts the file log once, on its main thread, with `FileLog.start`, and stops it once at the end with `stop`. The program passes `logger.ilog()` down to the code that logs.

```zig
const file_log = ziggy.log.file_log;

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

`file_log.defaultLogsDir(allocator, program_name)` gives `<program_name>/logs` in the system's temporary directory.

To let a user or a test choose the directory, read an environment variable of the program's own with `process_env.getEnv` and fall back to `defaultLogsDir`. A test that runs beside other tests gives each run a directory of its own this way.

## When a write fails

A log line that cannot be written to its file is reported on stderr, as `Could not write to the log file <path>: <error>`, and the line still goes to the console.

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

## Reading the log back

`file_log.readLogDetails(allocator, io, log_file_path)` gives the path of a log file and its header, as `ILogDetails`, for a bug report. `log.getLogDetails(allocator, io)` on a log gives the same for a file log, and a null path for the console log; on `services.log` it is the main thread's file log's. It reads the file, so call it from a task when the frontend is waiting.
