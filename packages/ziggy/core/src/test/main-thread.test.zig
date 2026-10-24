//
// Tests of the core's main thread. The handlers run on the main thread and share nothing with the test's thread: they tell the test
// what it needs to know by app events, and the test tells them by files it writes and by messages.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");
const helpers = @import("helpers.zig");

const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;

//
// wait-for-release: waits up to ten seconds for the file at the path it is given to exist, and returns whether it did in time. The test
// writes the file once its sendMessage has returned, so the handler finishes only after the message was passed on and sendMessage
// returned.
//
fn waitForReleaseHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    _ = services;
    _ = timers;
    _ = allocator;
    var waited_ms: u32 = 0;
    while (waited_ms < 10_000) : (waited_ms += 5) {
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
            return "released";
        }
        else |_| {}
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    return "timed out";
}

//
// Sends the frontend an app event naming the thread it is sent from, as {"<name>": <thread id>}.
//
fn sendThread(services: HandlerServices, io: std.Io, allocator: std.mem.Allocator, name: []const u8) !void {
    var buffer: [128]u8 = undefined;
    const event = try std.fmt.bufPrint(&buffer, "{{\"{s}\":{d}}}", .{ name, std.Thread.getCurrentId() });
    try services.sendEvent(io, allocator, event);
}

//
// which-thread: tells the frontend the thread it runs on and sets a timeout that tells the frontend its own thread.
//
fn whichThreadHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: struct {}) !void {
    _ = payload;
    try sendThread(services, io, allocator, "handlerThread");
    _ = try timers.setTimeout(io, .{
        .context = null,
        .function = sendTimerThread,
    }, 5);
}

//
// The which-thread handler's timeout.
//
fn sendTimerThread(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, services: ?*const anyopaque) void {
    _ = context;
    _ = timers;
    sendThread(ziggy.core.handlerServicesOf(services), io, allocator, "timerThread") catch @panic("out of memory sending an event from a timer");
}

//
// set-timeout: sets a timeout that sends the frontend {"timeout":"fired"} after the milliseconds given, and returns its id.
//
fn setTimeoutHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, milliseconds: u64) !ziggy.core.TimerId {
    _ = services;
    _ = allocator;
    return try timers.setTimeout(io, .{
        .context = null,
        .function = timeoutFired,
    }, milliseconds);
}

fn timeoutFired(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, services: ?*const anyopaque) void {
    _ = context;
    _ = timers;
    ziggy.core.handlerServicesOf(services).sendEvent(io, allocator, "{\"timeout\":\"fired\"}") catch @panic("out of memory sending an event from a timer");
}

//
// clear-timer: clears the timeout or the interval whose id it is given.
//
fn clearTimerHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, id: ziggy.core.TimerId) !void {
    _ = services;
    _ = io;
    _ = allocator;
    timers.clearTimeout(id);
}

//
// set-interval: sets an interval that sends the frontend {"interval":"ran"} every time it runs, and returns its id.
//
fn setIntervalHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, milliseconds: u64) !ziggy.core.TimerId {
    _ = services;
    _ = allocator;
    return try timers.setInterval(io, .{
        .context = null,
        .function = intervalRan,
    }, milliseconds);
}

fn intervalRan(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, services: ?*const anyopaque) void {
    _ = context;
    _ = timers;
    ziggy.core.handlerServicesOf(services).sendEvent(io, allocator, "{\"interval\":\"ran\"}") catch @panic("out of memory sending an event from a timer");
}

//
// The app of these tests.
//
const main_thread_app = registered: {
    var registered = ziggy.core.App(.{
        .messages = .{
            .@"wait-for-release" = waitForReleaseHandler,
            .@"which-thread" = whichThreadHandler,
            .@"set-timeout" = setTimeoutHandler,
            .@"clear-timer" = clearTimerHandler,
            .@"set-interval" = setIntervalHandler,
        },
        .tasks = .{},
        .menu = &.{},
        .ui_files = &[_]ziggy.ui_files.UiFile{},
    });
    registered.tasks = &helpers.task_handlers;
    break :registered registered;
};

//
// The number in the first delivered message that holds the key, as {"<key>": <number>} or {"id":...,"data":<number>}, or null when
// there is none.
//
fn numberAfter(native_app: *helpers.FakeNativeApp, key: []const u8) !?u64 {
    const index = native_app.indexOfContaining(std.testing.io, std.testing.allocator, key) orelse {
        return null;
    };
    const message = try native_app.messageAt(std.testing.io, std.testing.allocator, index);
    defer std.testing.allocator.free(message);
    const start = (std.mem.indexOf(u8, message, key) orelse {
        return null;
    }) + key.len;
    var end = start;
    while (end < message.len and std.ascii.isDigit(message[end])) : (end += 1) {}
    return try std.fmt.parseInt(u64, message[start..end], 10);
}

test "sendMessage passes the message on and returns before its handler has run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const release_path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/released", .{tmp.sub_path});
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), main_thread_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var message_buffer: [512]u8 = undefined;
    native_app.sendMessage(std.testing.allocator, try std.fmt.bufPrint(&message_buffer, "{{\"kind\":\"app\",\"id\":1,\"name\":\"wait-for-release\",\"data\":\"{s}\"}}", .{release_path}));
    // Had the handler run inside sendMessage, it would have waited out its ten seconds before this line, and responded that it timed
    // out.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "released",
        .data = "",
    });
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true,\"data\":\"released\"}");
}

test "a message's handler and a timer run on the core's main thread, which is not the thread that sent the message" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), main_thread_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"name\":\"which-thread\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"timerThread\":");
    const handler_thread = (try numberAfter(&native_app, "\"handlerThread\":")).?;
    const timer_thread = (try numberAfter(&native_app, "\"timerThread\":")).?;
    try std.testing.expect(handler_thread != std.Thread.getCurrentId());
    try std.testing.expectEqual(handler_thread, timer_thread);
}

test "a timeout runs once after its time, and one cleared before then never runs" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), main_thread_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"name\":\"set-timeout\",\"data\":20}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"timeout\":\"fired\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":7,\"name\":\"set-timeout\",\"data\":200}");
    const id = (try numberAfter(&native_app, "{\"id\":7,\"ok\":true,\"data\":")).?;
    var message_buffer: [128]u8 = undefined;
    try native_app.send(std.testing.io, std.testing.allocator, try std.fmt.bufPrint(&message_buffer, "{{\"kind\":\"app\",\"name\":\"clear-timer\",\"data\":{d}}}", .{id}));
    ziggy.fake_native_app.sleepMs(std.testing.io, 300);
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "{\"timeout\":\"fired\"}"));
}

test "an interval runs every time its time passes until it is cleared" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), main_thread_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"set-interval\",\"data\":10}");
    const id = (try numberAfter(&native_app, "{\"id\":1,\"ok\":true,\"data\":")).?;
    var waited_ms: u32 = 0;
    while (native_app.countContaining(std.testing.io, std.testing.allocator, "{\"interval\":\"ran\"}") < 3 and waited_ms < 20_000) : (waited_ms += 2) {
        ziggy.fake_native_app.sleepMs(std.testing.io, 2);
    }
    var message_buffer: [128]u8 = undefined;
    try native_app.send(std.testing.io, std.testing.allocator, try std.fmt.bufPrint(&message_buffer, "{{\"kind\":\"app\",\"name\":\"clear-timer\",\"data\":{d}}}", .{id}));
    // The main thread has handled the clear, so no run comes after the runs counted now.
    const runs = native_app.countContaining(std.testing.io, std.testing.allocator, "{\"interval\":\"ran\"}");
    try std.testing.expect(runs >= 3);
    ziggy.fake_native_app.sleepMs(std.testing.io, 60);
    try std.testing.expectEqual(runs, native_app.countContaining(std.testing.io, std.testing.allocator, "{\"interval\":\"ran\"}"));
}

test "a drop reaches the main thread before a message the frontend sends after it, such as getPathForFile's" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dropped.txt",
        .data = "xyz",
    });
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "dropped.txt" });
    defer std.testing.allocator.free(path);
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const paths_json = try ziggy.json.stringify(std.testing.allocator, &[_][]const u8{path});
    defer std.testing.allocator.free(paths_json);
    // No wait between the two: the drop is recorded by the main thread before it reads the message that follows it.
    try native_app.filesDropped(std.testing.allocator, paths_json);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":5,\"name\":\"get-dropped-paths\"}");
    const expected = try ziggy.json.stringify(std.testing.allocator, .{
        .id = 5,
        .ok = true,
        .data = ziggy.json.Raw{ .text = paths_json },
    });
    defer std.testing.allocator.free(expected);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, expected);
}

test "a drop of a path that is not a readable file is refused on the calling thread, and the last drop stays" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try std.testing.expectError(error.FileNotFound, native_app.filesDropped(std.testing.allocator, "[\"/no/such/file/anywhere\"]"));
    try std.testing.expectError(error.NotAnArrayOfPaths, native_app.filesDropped(std.testing.allocator, "{\"not\":\"an array\"}"));
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":6,\"name\":\"get-dropped-paths\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":6,\"ok\":true,\"data\":[]}");
}

//
// The number of threads the process has that are not ending, read from /proc/self/task, which Linux and Android have. A thread that has
// been joined is still listed there for a moment while the kernel finishes ending it, so a thread that is ending is not counted: the
// Linux unit-test job failed with "expected 1, found 3" when two of the threads stop had joined were still listed.
//
fn threadCount() !usize {
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, "/proc/self/task", .{
        .iterate = true,
    });
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (!threadEnding(entry.name)) {
            count += 1;
        }
    }
    return count;
}

//
// Whether the thread with the id given is ending or gone: the kernel sets PF_EXITING (0x4) in the flags of /proc/self/task/<id>/stat
// before a joined thread's join returns. Read with the Linux system calls, because reading the file of a thread that is gone fails with
// ESRCH, which std.Io reports as an unexpected error with a stack trace.
//
fn threadEnding(id: []const u8) bool {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/self/task/{s}/stat", .{id}) catch @panic("thread id too long");
    const opened = std.os.linux.open(path.ptr, .{ .CLOEXEC = true }, 0);
    if (std.os.linux.errno(opened) != .SUCCESS) {
        return true;
    }
    const fd: i32 = @intCast(opened);
    defer _ = std.os.linux.close(fd);
    var stat_buffer: [1024]u8 = undefined;
    const read = std.os.linux.read(fd, &stat_buffer, stat_buffer.len);
    if (std.os.linux.errno(read) != .SUCCESS) {
        return true;
    }
    const stat = stat_buffer[0..read];
    // The thread's name is in parentheses and may hold spaces, so the fields are counted from the last closing parenthesis: state,
    // ppid, pgrp, session, tty_nr, tpgid, then flags.
    const name_end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse @panic("a thread's stat has no name");
    var fields = std.mem.tokenizeScalar(u8, stat[name_end + 1 ..], ' ');
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) {
        if (index == 6) {
            const flags = std.fmt.parseInt(u64, field, 10) catch @panic("a thread's flags are not a number");
            return flags & 0x4 != 0;
        }
    }
    @panic("a thread's stat has no flags");
}

test "destroying a core with tasks still running stops the main thread, every worker and the test control connection" {
    const counts_threads = builtin.os.tag == .linux;
    const before = if (counts_threads) try threadCount() else 0;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    var native_app_released = false;
    defer if (!native_app_released) native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(3, 2);
    var port_file_buffer: [256]u8 = undefined;
    const port_file = try std.fmt.bufPrintZ(&port_file_buffer, ".zig-cache/tmp/{s}/port.txt", .{tmp.sub_path});
    config.test_mode = true;
    config.test_port_file = port_file.ptr;
    try native_app.start(std.testing.io, std.testing.allocator, config, helpers.app);
    var destroyed = false;
    defer if (!destroyed) native_app.stop(std.testing.io, std.testing.allocator);
    // Three workers: the spin task holds one, the parent another while it waits for its children, and the sleep the third, so the
    // parent's children wait in the queue.
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"s1\",\"taskType\":\"spin\",\"source\":\"s\"}}");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"p1\",\"taskType\":\"parent\",\"source\":\"s\",\"data\":{\"children\":4,\"childMs\":100000}}}");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"q1\",\"taskType\":\"sleep\",\"source\":\"s\",\"data\":{\"ms\":100000}}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"s1\",\"source\":\"s\",\"data\":{\"step\":1}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"start\":\"sleep\"");
    // Stop returns only once the main thread has stopped, which it does only once every worker and the test control connection have.
    // The fake native app's own thread ends when the fake native app is released.
    destroyed = true;
    native_app.stop(std.testing.io, std.testing.allocator);
    native_app_released = true;
    native_app.deinit(std.testing.io, std.testing.allocator);
    if (counts_threads) {
        try std.testing.expectEqual(before, try threadCount());
    }
}
