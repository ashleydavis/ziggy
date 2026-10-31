//
// Tests of an app's log files, which the main thread starts before it makes the handler services and stops after the app's last
// on_destroy call, for an app with a name. An app's build gives it the name, title and version of its app.zon; Ziggy's own tests are
// built for no app, so these tests set them.
//

const std = @import("std");
const ziggy = @import("ziggy");
const helpers = @import("helpers.zig");

const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const DestroyPhase = ziggy.core.DestroyPhase;

//
// Logs a line from on_create through the services' log, which the log files must hold, and tells the test whether that log writes a
// file.
//
fn logOnCreate(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) !void {
    _ = arguments;
    _ = timers;
    services.log.info("logged by on_create");
    try services.sendEvent(io, allocator, if (services.log.logFilePath() != null) "{\"onCreateLog\":\"file\"}" else "{\"onCreateLog\":\"other\"}");
}

//
// Logs a line from each call of on_destroy through the services' log, both of which the log files must hold before their footer, and
// tells the test whether that log still writes a file once the tasks have stopped.
//
fn logOnDestroy(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, phase: DestroyPhase) void {
    _ = timers;
    switch (phase) {
        .before_tasks_stop => services.log.info("logged by on_destroy"),
        .after_tasks_stopped => {
            services.log.info("logged by on_destroy after the tasks stopped");
            services.sendEvent(io, allocator, if (services.log.logFilePath() != null) "{\"afterStopLog\":\"file\"}" else "{\"afterStopLog\":\"other\"}") catch @panic("out of memory telling the test");
        },
    }
}

//
// Configures the log with verbose lines on, then again, and tells the test whether the services' log shows verbose lines before and
// after, and what the second call returned.
//
fn configureLogOnCreate(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) !void {
    _ = arguments;
    _ = timers;
    const before = services.log.verboseEnabled();
    try services.configureLog(.{
        .verbose = true,
        .debug = false,
        .tools = false,
    });
    const after = services.log.verboseEnabled();
    const second: []const u8 = if (services.configureLog(.{
        .verbose = false,
        .debug = false,
        .tools = false,
    })) "configured" else |err| @errorName(err);
    const event = try std.fmt.allocPrint(allocator, "{{\"verboseBefore\":{},\"verboseAfter\":{},\"verboseAfterSecond\":{},\"second\":\"{s}\"}}", .{
        before,
        after,
        services.log.verboseEnabled(),
        second,
    });
    try services.sendEvent(io, allocator, event);
}

//
// Tells the test the arguments the app is given, as a JSON list.
//
fn sendArgumentsOnCreate(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) !void {
    _ = timers;
    const listed = try std.json.Stringify.valueAlloc(allocator, arguments, .{});
    const event = try std.fmt.allocPrint(allocator, "{{\"arguments\":{s}}}", .{listed});
    try services.sendEvent(io, allocator, event);
}

//
// Fails, so a test can tell whether on_create was called.
//
fn failOnCreate(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) !void {
    _ = arguments;
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    return error.OnCreateRan;
}

//
// An app named logged-app, titled Logged App, at version 4.5.6, which logs from on_create and on_destroy.
//
const logged_app = named: {
    var registered = ziggy.core.App(.{
        .messages = .{},
        .tasks = .{},
        .menu = &.{},
        .ui_files = &[_]ziggy.ui_files.UiFile{},
        .on_create = logOnCreate,
        .on_destroy = logOnDestroy,
    });
    registered.name = "logged-app";
    registered.title = "Logged App";
    registered.version = "4.5.6";
    break :named registered;
};

//
// An app named failing-app, whose on_create fails.
//
const failing_app = named: {
    var registered = ziggy.core.App(.{
        .messages = .{},
        .tasks = .{},
        .menu = &.{},
        .ui_files = &[_]ziggy.ui_files.UiFile{},
        .on_create = failOnCreate,
    });
    registered.name = "failing-app";
    break :named registered;
};

//
// An app named configured-app, which configures its log in on_create.
//
const configured_app = named: {
    var registered = ziggy.core.App(.{
        .messages = .{},
        .tasks = .{},
        .menu = &.{},
        .ui_files = &[_]ziggy.ui_files.UiFile{},
        .on_create = configureLogOnCreate,
    });
    registered.name = "configured-app";
    break :named registered;
};

//
// An app with no name, which configures its log in on_create.
//
const configured_unnamed_app = ziggy.core.App(.{
    .messages = .{},
    .tasks = .{},
    .menu = &.{},
    .ui_files = &[_]ziggy.ui_files.UiFile{},
    .on_create = configureLogOnCreate,
});

//
// An app as Ziggy's own tests build it, for no app, so with no name.
//
const unnamed_app = ziggy.core.App(.{
    .messages = .{},
    .tasks = .{},
    .menu = &.{},
    .ui_files = &[_]ziggy.ui_files.UiFile{},
});

//
// Reads the one log file in the directory whose name starts with the prefix, the error log file when `errors` is true or else the
// other one. Fails when the directory does not hold exactly two files.
//
fn readLogFile(allocator: std.mem.Allocator, directory_path: []const u8, prefix: []const u8, errors: bool) ![]u8 {
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, directory_path, .{
        .iterate = true,
    });
    defer directory.close(std.testing.io);
    var file_count: usize = 0;
    var found: ?[]u8 = null;
    errdefer if (found) |text| allocator.free(text);
    var iterator = directory.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        file_count += 1;
        try std.testing.expect(std.mem.startsWith(u8, entry.name, prefix));
        if (std.mem.endsWith(u8, entry.name, "-errors.log") == errors) {
            found = try directory.readFileAlloc(std.testing.io, entry.name, allocator, .limited(1024 * 1024));
        }
    }
    try std.testing.expectEqual(@as(usize, 2), file_count);
    return found orelse error.NoLogFile;
}

test "an app with a name has its two log files in the logs directory of its data directory, named after it and headed with its title and version, open from before on_create until after its last on_destroy call" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), logged_app);
    native_app.stop(std.testing.io, std.testing.allocator);
    const logs_dir = try std.fs.path.join(std.testing.allocator, &.{ std.mem.sliceTo(&native_app.data_dir_path, 0), "logs" });
    defer std.testing.allocator.free(logs_dir);
    const written = try readLogFile(std.testing.allocator, logs_dir, "logged-app-", false);
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.startsWith(u8, written, "=" ** 80 ++ "\nLogged App\n"));
    try std.testing.expect(std.mem.indexOf(u8, written, "\nVersion: 4.5.6\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "] [INFO] logged by on_create\n") != null);
    const destroy_line = std.mem.indexOf(u8, written, "] [INFO] logged by on_destroy\n") orelse return error.NoDestroyLine;
    const footer = std.mem.indexOf(u8, written, "\n--- Log End ---\n") orelse return error.NoFooter;
    try std.testing.expect(destroy_line < footer);
    const after_stop_line = std.mem.indexOf(u8, written, "] [INFO] logged by on_destroy after the tasks stopped\n") orelse return error.NoAfterStopLine;
    try std.testing.expect(after_stop_line < footer);
    // The services' log was the file log in on_create and in the last on_destroy call.
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"onCreateLog\":\"file\"");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"afterStopLog\":\"file\"");
}

test "an app's log files go in the logs directory of the directory <NAME>_LOG_DIR names when it is set" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    const data_dir = std.mem.sliceTo(&native_app.data_dir_path, 0);
    const elsewhere = try std.fs.path.join(std.testing.allocator, &.{ data_dir, "elsewhere" });
    defer std.testing.allocator.free(elsewhere);
    // The core is given the environment of the thread that starts it.
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("LOGGED_APP_LOG_DIR", elsewhere);
    ziggy.utils.process_env.setEnvironMap(&environ_map);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), logged_app);
    native_app.stop(std.testing.io, std.testing.allocator);
    const logs_dir = try std.fs.path.join(std.testing.allocator, &.{ elsewhere, "logs" });
    defer std.testing.allocator.free(logs_dir);
    const written = try readLogFile(std.testing.allocator, logs_dir, "logged-app-", false);
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.startsWith(u8, written, "=" ** 80 ++ "\nLogged App\n"));
    const default_logs_dir = try std.fs.path.join(std.testing.allocator, &.{ data_dir, "logs" });
    defer std.testing.allocator.free(default_logs_dir);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, default_logs_dir, .{}));
}

test "configureLog turns on the verbose lines of an app's file log once, and a second call fails without changing them" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), configured_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"verboseBefore\":false,\"verboseAfter\":true,\"verboseAfterSecond\":true,\"second\":\"LogAlreadyConfigured\"");
}

test "configureLog turns on the verbose lines of the console log of an app with no name once, and a second call fails without changing them" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), configured_unnamed_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"verboseBefore\":false,\"verboseAfter\":true,\"verboseAfterSecond\":true,\"second\":\"LogAlreadyConfigured\"");
}

test "an app is given the native app's command-line arguments, and none when the native app has none" {
    const arguments_app = ziggy.core.App(.{
        .messages = .{},
        .tasks = .{},
        .menu = &.{},
        .ui_files = &[_]ziggy.ui_files.UiFile{},
        .on_create = sendArgumentsOnCreate,
    });
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    const args = [_][*:0]const u8{ "--verbose", "-geometry=800x600" };
    var config = native_app.config(1, 1);
    config.arg_count = args.len;
    config.args = &args;
    try native_app.start(std.testing.io, std.testing.allocator, config, arguments_app);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"arguments\":[\"--verbose\",\"-geometry=800x600\"]}");
    native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), arguments_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"arguments\":[]}");
}

test "an app with no name has no log files" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), unnamed_app);
    native_app.stop(std.testing.io, std.testing.allocator);
    const logs_dir = try std.fs.path.join(std.testing.allocator, &.{ std.mem.sliceTo(&native_app.data_dir_path, 0), "logs" });
    defer std.testing.allocator.free(logs_dir);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, logs_dir, .{}));
}

test "the core does not start, and on_create is not called, when the app's log files cannot be made" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.data_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "a-file",
        .data = "not a directory",
    });
    var path_buffer: [256]u8 = undefined;
    const data_dir = try std.fmt.bufPrintZ(&path_buffer, "{s}/a-file/data", .{std.mem.sliceTo(&native_app.data_dir_path, 0)});
    var config = native_app.config(1, 1);
    config.data_dir = data_dir.ptr;
    native_app.start(std.testing.io, std.testing.allocator, config, failing_app) catch |err| {
        try std.testing.expect(err != error.OnCreateRan);
        return;
    };
    return error.CoreStarted;
}

test "App gives an app the name, title and version its build gives Ziggy, which a core built for no app does not have" {
    try std.testing.expect(unnamed_app.name == null);
    try std.testing.expect(unnamed_app.title == null);
    try std.testing.expect(unnamed_app.version == null);
}

//
// Tells the test whether the services' log writes a file, from on_create of an app with no name.
//
fn reportConsoleLog(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) !void {
    _ = arguments;
    _ = timers;
    try services.sendEvent(io, allocator, if (services.log.logFilePath() == null) "{\"servicesLog\":\"no file\"}" else "{\"servicesLog\":\"file\"}");
}

//
// An app with no name, so no file log, which reports its services' log when it starts.
//
const console_log_app = ziggy.core.App(.{
    .messages = .{},
    .tasks = .{},
    .menu = &.{},
    .ui_files = &[_]ziggy.ui_files.UiFile{},
    .on_create = reportConsoleLog,
});

test "the services' log of an app with no name writes no file" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), console_log_app);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"servicesLog\":\"no file\"");
    native_app.stop(std.testing.io, std.testing.allocator);
}
