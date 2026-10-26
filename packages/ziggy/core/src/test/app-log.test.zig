//
// Tests of an app's log files, which the main thread starts before the app's on_create and stops once every task has ended, for an app
// with a name. An app's build gives it the name, title and version of its app.zon; Ziggy's own tests are built for no app, so these
// tests set them.
//

const std = @import("std");
const ziggy = @import("ziggy");
const helpers = @import("helpers.zig");

const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const DestroyPhase = ziggy.core.DestroyPhase;

//
// Logs a line from on_create, which the log files must hold.
//
fn logOnCreate(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) !void {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    ziggy.task_queue.utils.log.log.info("logged by on_create");
}

//
// Logs a line from each call of on_destroy: the one before the tasks stop, which the log files must hold before their footer, and a
// warning (which the console writes to standard error, not standard output) once they have stopped, which comes after the file log has
// stopped and must not be in the log files.
//
fn logOnDestroy(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, phase: DestroyPhase) void {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    switch (phase) {
        .before_tasks_stop => ziggy.task_queue.utils.log.log.info("logged by on_destroy"),
        .after_tasks_stopped => ziggy.task_queue.utils.log.log.warn("logged by on_destroy after the file log stopped"),
    }
}

//
// Fails, so a test can tell whether on_create was called.
//
fn failOnCreate(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) !void {
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

test "an app with a name has its two log files in the logs directory of its data directory, named after it and headed with its title and version, open from before on_create until the tasks have stopped" {
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
    try std.testing.expect(std.mem.indexOf(u8, written, "after the file log stopped") == null);
    const errors_written = try readLogFile(std.testing.allocator, logs_dir, "logged-app-", true);
    defer std.testing.allocator.free(errors_written);
    try std.testing.expect(std.mem.indexOf(u8, errors_written, "after the file log stopped") == null);
}

test "an app's log files go in the logs directory of the directory <NAME>_LOG_DIR names when it is set" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    const data_dir = std.mem.sliceTo(&native_app.data_dir_path, 0);
    const elsewhere = try std.fs.path.join(std.testing.allocator, &.{ data_dir, "elsewhere" });
    defer std.testing.allocator.free(elsewhere);
    // The core is given the environment of the thread that starts it.
    const previous = ziggy.task_queue.utils.process_env.getEnvironMap();
    defer ziggy.task_queue.utils.process_env.setEnvironMap(previous);
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("LOGGED_APP_LOG_DIR", elsewhere);
    ziggy.task_queue.utils.process_env.setEnvironMap(&environ_map);
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
