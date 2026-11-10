# Automatic file log for command line tools

## Overview

Ziggy sets up a GUI app's file log by itself: the app gives its name, title and version in `app.zon`, Ziggy's build passes them to the core as build options, and the core's main thread starts and stops the log (`startFileLog` in `packages/ziggy/core/src/lib/core.zig`). A command line tool that uses Ziggy has no such path: it must call `FileLog.start` and `stop` itself. This plan gives a command line tool the same model as a GUI app. The tool declares itself with `ziggy.core.CliTool(.{ ... })` in its main source file, gives its details in `app.zon`, and is built with a new `addCliTool` in Ziggy's `build.zig`. Ziggy provides the program's `main`, which sets up the file log from `app.zon`, runs the tool's tasks on Ziggy's worker pool, calls the tool's `run` and closes the log on every way out. No app or tool starts or stops the file log.

## Issues

## Steps

1. **Move the code that turns app details into a file log into the log package.**
   - Create `packages/ziggy/log/src/lib/program-log.zig` with:
     - `pub const IProgramDetails = struct { name: []const u8, title: []const u8, version: ?[]const u8 }`.
     - `pub fn logDirVariable(allocator: std.mem.Allocator, name: []const u8) ![]const u8`: the name in capitals with each dash as an underscore, followed by `_LOG_DIR` (the loop now in `startFileLog` in `core.zig`).
     - `pub fn readEnvironmentVariable(arena: std.mem.Allocator, variable: []const u8) !?[]const u8`: moved from `environmentVariable` in `core.zig`, unchanged in behaviour (the map given to `utils.process_env.setEnvironMap` when there is one, else the process's environment).
     - `pub fn startProgramLog(allocator: std.mem.Allocator, io: std.Io, details: IProgramDetails, default_logs_dir: []const u8, command: ?[]const u8) !*file_log.FileLog`: the `logs` directory of the directory `<NAME>_LOG_DIR` names when it is set, else `default_logs_dir`; then `FileLog.start` with `file_prefix = details.name`, `title = details.title`, `version = details.version`, `command`, `header_lines = &.{}` and the three console options false.
   - Export it from `packages/ziggy/log/src/index.zig` as `pub const program_log = @import("lib/program-log.zig");`.
   - In `core.zig`, delete the functions `startFileLog` and `environmentVariable` and change the call in `mainThread` (the `if (app.name) |name|` block) to `logging.program_log.startProgramLog(allocator, io, .{ .name = name, .title = app.title orelse name, .version = app.version }, <data_dir joined with "logs">, null)`. The join uses an arena freed straight after the call.
   - `mise exec -- zig build test --summary all` in `ziggy/` compiles and passes, including `packages/ziggy/core/src/test/app-log.test.zig`.

2. **Add the command line tool declaration to the core.**
   - Create `packages/ziggy/core/src/lib/cli.zig` with:
     - `pub const CliServices = struct` holding a pointer to the tool's main-thread state, with:
       - `log: logging.ILog`, the tool's file log.
       - `pub fn configureLog(self: CliServices, options: logging.ILogOptions) !void`: configures the console of the file log once, as `MainServices.configureLog` in `core.zig` does; a second call returns `error.LogAlreadyConfigured`.
       - `pub fn runTask(self: CliServices, io: std.Io, allocator: std.mem.Allocator, task_type: []const u8, data_json: []const u8) ![]const u8`: makes a task id with `utils.random_uuid_generator.RandomUuidGenerator`, adds the task to the pool with `WorkerPool.addTask` (source `"cli"`, priority `.normal` from `task_runner.TaskPriority`), then loops on `WorkerPool.waitForWorkerMessage` and `takeNotice` until the `.task_end` notice for that id arrives. It returns the result JSON copied with `allocator`, or `error.TaskFailed` after logging the task's error message with `log.@"error"`. Every other notice is freed with `Notice.deinit`.
     - `pub const RunFn = *const fn (services: CliServices, timers: timers_lib.Timers, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) anyerror!u8`: the tool's code, given its arguments after the program's name, returning the exit code.
     - `pub const RegisteredCliTool = struct { run: RunFn, tasks: []const task_runner.TaskHandlerEntry, describe_error: ?types.ErrorDescriber, name: ?[]const u8, title: ?[]const u8, version: ?[]const u8 }`, with `name`, `title` and `version` from `build_options` as `App` sets them in `app.zig`.
     - `pub fn CliTool(comptime definition: anytype) RegisteredCliTool`: takes `.run` (required), `.tasks` (required, made with `app.zig`'s `taskTable`) and `.describe_error` (optional). An unknown or missing field fails the build with a `@compileError` naming it, in the same way `App` does with `app_fields`.
     - `pub fn runMain(init: std.process.Init, tool: RegisteredCliTool) u8`: hands the environment to `utils.process_env.setEnvironMap`, reads the arguments, joins them with spaces for the header's command line, and calls `runWith`.
     - `pub fn runWith(allocator: std.mem.Allocator, io: std.Io, command: []const u8, arguments: []const []const u8, tool: RegisteredCliTool) u8`. It:
       - Starts the file log with `program_log.startProgramLog`, `default_logs_dir` from `file_log.defaultLogsDir(allocator, name)`. A tool built with no name (Ziggy's own tests of this file) logs to a `ConsoleLog`.
       - Makes a `MessageQueue` and a `WorkerPool` from `tool.tasks` with `observe = true`, as `mainThread` in `core.zig` does without the native app's handlers.
       - Calls `tool.run`. An error is logged with `log.exception("The command failed", err)` and gives exit code 1.
       - Shuts the pool down with `WorkerPool.shutdown` and stops the file log with `stop`, on every return path, with `defer`.
   - In `core.zig`, add `pub const CliTool = cli_lib.CliTool;`, `pub const CliServices = cli_lib.CliServices;` and `pub const RegisteredCliTool = cli_lib.RegisteredCliTool;` beside `pub const App = app_lib.App;`, with `const cli_lib = @import("cli.zig");`.
   - Add unit tests in `packages/ziggy/core/src/test/cli.test.zig` (see Unit Tests). They compile and pass with `mise exec -- zig build test --summary all`.

3. **Add the program root and the build function.**
   - Create `packages/ziggy/core/src/cli-root.zig`: imports `ziggy` and `cli-tool`, fails the build with `@compileError("The command line tool's source file must declare `pub const cli = ziggy.core.CliTool(.{ ... });`.")` when `cli-tool` has no `cli` declaration, and declares `pub fn main(init: std.process.Init) u8 { return ziggy.core.cli.runMain(init, cli_tool.cli); }`. Export `cli` from `packages/ziggy/core/src/index.zig` as `pub const cli = @import("lib/cli.zig");`.
   - In `ziggy/build.zig`, add `pub const ICliTool = struct { name: []const u8, title: []const u8, source_file: []const u8, imports: []const IImport }` and `pub fn addCliTool(b: *std.Build, ziggy: IZiggy, tool: ICliTool, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile`. It builds the tool's source file as a module importing `ziggy` and `tool.imports`, makes the root module from `ziggy.dependency.path("packages/ziggy/core/src/cli-root.zig")` importing `ziggy` and the tool's module as `cli-tool`, makes an executable named `tool.name`, adds a step named `tool.name` with the description `Build <title>` that installs it, and returns the executable. The tool's details come from `app.zon` through `dependency`, which already calls `readAppDetails`.

4. **Add the Ziggy test command line tool.**
   - Create `apps/ziggy-test-cli/` with:
     - `build.zig.zon`, taking Ziggy by path `../..` as `apps/ziggy-test-app/build.zig.zon` does.
     - `app.zon` with `.name = "ziggy-test-cli"`, `.title = "Ziggy test CLI"` and `.version = "1.0.0"`.
     - `build.zig`, which calls `ziggy.dependency` and `addCliTool` for `src/main.zig`, and a `test` step running the unit tests under `src/test`.
     - `src/main.zig`, which declares `pub const cli = ziggy.core.CliTool(.{ ... })`: a `.run` that logs `info` "Started the test CLI", runs one task of type `hello` with `{"name":"world"}`, logs its result, logs a `warn` "A test warning" and returns 0, or returns 3 when its first argument is `--fail`, after logging `error` "Failing as asked". The `hello` task logs "Hello from a task" and returns `{"greeting":"Hello world"}`.
     - `src/test/main.test.zig`, unit tests of the `hello` task's handler.
     - `README.md`, which says what the tool is for and how its smoke test runs it.
   - In Ziggy's `build.zig` `build` function, add a step to the `test` step that runs `zig build test --summary all` in `apps/ziggy-test-cli`, with no `bundle:ui` step before it.

5. **Add the command line tool's smoke test.**
   - Create `smoke-tests/cli/log-files/test.sh`. It sources `smoke-tests/lib/test-lib.sh` and gets a directory from `ziggy_test_temp_dir`. It builds the tool with `zig build ziggy-test-cli` in `apps/ziggy-test-cli`, then runs the built program twice with `ZIGGY_TEST_CLI_LOG_DIR` set to that directory: once with no arguments and once with `--fail`. It checks:
     - The exit codes are 0 and 3.
     - `logs/ziggy-test-cli-*.log` holds, for the first run, "Ziggy test CLI Log" in the header, "Version: 1.0.0", "Command:" with the program's path, "Started the test CLI", "[Worker 1] Hello from a task", "Hello world" and the footer's "Completed:" line.
     - The matching `-errors.log` holds "A test warning".
     - The second run's files hold "Failing as asked" and its footer.
   - Create `smoke-tests/cli/run.sh`, which runs every `test.sh` under `smoke-tests/cli/`, and `smoke-tests/cli/run.md` beside it, saying what it runs and how.
   - Add `"test:smoke:cli": "bash ./smoke-tests/cli/run.sh"` to `ziggy/package.json` scripts.
   - `mise exec -- bun run test:smoke:cli` passes.

6. **Write the documentation.**
   - `docs/user-guide/logging.md`:
     - Rewrite "The file log in a command line tool" to say the tool writes no code to have log files: it gives its details in `app.zon`, like an app. The files go in the `logs` directory of `<NAME>_LOG_DIR` when that is set, else `<name>/logs` in the system's temporary directory. The header's `Command:` line is the tool's command line.
     - Say the tool configures its console from its own options with `services.configureLog`.
     - Remove the `FileLog.start` example, the configuration table, the `start`/`stop` allocator paragraph, the paragraph about starting it in `main` and "Choosing the logs directory".
   - Create `docs/user-guide/command-line-tools.md`, covering:
     - Declaring a tool with `ziggy.core.CliTool` and its fields.
     - `run`'s arguments and exit code.
     - `CliServices` (`log`, `configureLog`, `runTask`).
     - Building with `addCliTool`.
     - Link it from `docs/user-guide.md` beside the other user guide pages.
   - `docs/development/architecture.md`: add a paragraph that the command line tool's `main` is `cli-root.zig`, which calls `cli.runMain`, and that both it and the GUI app's main thread start their file log with `program_log.startProgramLog`.
   - `docs/development/packages.md`: add `program-log.zig` to the log package's row and `cli.zig` to the core's row, in the style of the existing rows.

## Unit Tests

- `packages/ziggy/log/src/test/program-log.test.zig`:
  - `logDirVariable` gives `MY_APP_LOG_DIR` for `my-app`.
  - `startProgramLog` writes its files in `default_logs_dir` when `<NAME>_LOG_DIR` is not set.
  - `startProgramLog` writes in `<value>/logs` when it is set (with `setEnvironMap`).
  - The header holds the title, the version and the command when given.
  - `readEnvironmentVariable` reads from the given map when one is set.
- `packages/ziggy/core/src/test/app-log.test.zig`: keep every existing test passing unchanged; they cover `mainThread`'s new call.
- `packages/ziggy/core/src/test/cli.test.zig`:
  - `runWith` with a named tool writes both log files in the directory `<NAME>_LOG_DIR` names, with the header's command line and the footer.
  - `run`'s return value is the exit code.
  - An error from `run` gives exit code 1 and an exception line in the error file.
  - `runTask` returns a task's result JSON.
  - `runTask` returns `error.TaskFailed` and logs the error for a failing task.
  - A task's log line reaches the file tagged `Worker <id>`.
  - `configureLog` succeeds once and returns `error.LogAlreadyConfigured` the second time.
  - `CliTool` registers the tasks and `run` it is given.
  - The test tools' `name`, `title` and `version` are set directly on a `RegisteredCliTool` value, since `build_options` are null in Ziggy's own tests.
- `apps/ziggy-test-cli/src/test/main.test.zig`: the `hello` task returns `{"greeting":"Hello world"}` for `{"name":"world"}`.

## Smoke Tests

- `smoke-tests/cli/log-files/test.sh` (step 5): runs the built `ziggy-test-cli` program and checks its exit codes and both log files, for a run that succeeds and one that fails.
- `smoke-tests/26-log-files/test.sh`: unchanged; run it to confirm the GUI app's log files still work after step 1.

## Verify

- In `ziggy/`:
  - `mise exec -- zig build test --summary all` compiles and passes. This includes the log, core, template, test app and test CLI unit tests.
  - `mise exec -- bun run test:smoke:cli` passes.
  - `mise exec -- bun run test:smoke` passes on Linux, including `26-log-files`.
- `mise exec -- bun run test:smoke:android` and `mise exec -- bun run test:smoke:ios` run the GUI app's log test on mobile. Step 1 changes the core, which every mobile app links, so run the Android suite on this machine. The iOS suite needs a Mac and is CI-only.

## Notes

- The human's request: the file log is set up for any command line tool or GUI app that uses Ziggy, never started by the app, which only chooses its configuration, as a GUI app does now with `app.zon`.
- The human chose no documentation review stop. The documentation is written in the last step.
- A command line tool gets its log through a `main` that Ziggy provides (`cli-root.zig`), in the same way a GUI app's backend gets its C interface from `app-root.zig`. A Ziggy program cannot have its log set up without Ziggy owning its entry point, so this is the only way to meet the request.
- `FileLog.start` and `stop` stay public in the log package: the core and the tests call them. The user guide stops presenting them as something a program calls.
- The default logs directory for a command line tool is `file_log.defaultLogsDir(allocator, name)` (`<temporary directory>/<name>/logs`), the directory the user guide already gives for a program with no data directory.
- `header_lines` stays empty for both GUI apps and command line tools, as it is for GUI apps now. A tool that wants extra header lines is a later change.
- Photosphere's CLI (`photosphere/apps/cli-zig`) has its own `FileLogger` and worker pool. Moving it to `CliTool` is a separate change in that repository and is not part of this plan.
- No app has to change its code for this change, so `docs/upgrade-notes.md` gets no line.
- The plan has no Release step (no commit, push or tag was asked for) and no Clean up step (the plan deletes no file).
