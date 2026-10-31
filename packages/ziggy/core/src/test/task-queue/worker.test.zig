const std = @import("std");
const task_queue_zig = @import("ziggy").task_queue;
const utils = ziggy.utils;
const MuteLog = ziggy.log.mute_log.MuteLog;
const ILog = ziggy.log.ILog;
const worker = task_queue_zig.worker;
const types = task_queue_zig.types;
const TaskContext = task_queue_zig.task_context.TaskContext;
const errors = utils.errors;
const ziggy = @import("ziggy");
const Timers = ziggy.timers.Timers;

//
// A handler that returns its data under the key "echo".
//
fn echoHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = timers;
    _ = io;
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "echo", data);
    try object.put(allocator, "taskId", .{ .string = context.taskId });
    return .{ .object = object };
}

//
// A handler that returns 1.
//
fn oneHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = timers;
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return .{ .integer = 1 };
}

//
// A handler that throws.
//
fn throwingHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = timers;
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return errors.throwError("Handler failed", .{});
}

//
// Ignores sent events.
//
fn ignoreEvent(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, event: std.json.Value) void {
    _ = io;
    _ = allocator;
    _ = context;
    _ = event;
}

//
// The handlers the tests run, as an app lists them.
//
const handlers = [_]worker.IHandlerEntry{
    .{ .type = "worker-test-one", .handler = oneHandler },
    .{ .type = "worker-test-echo", .handler = echoHandler },
    .{ .type = "worker-test-throw", .handler = throwingHandler },
    .{ .type = "worker-test-available", .handler = oneHandler },
};

test "getHandler finds the handler a list gives for a task type, and none for a type it does not have" {
    try std.testing.expect(worker.getHandler(&handlers, "worker-test-one") == oneHandler);
    try std.testing.expect(worker.getHandler(&handlers, "worker-test-echo") == echoHandler);
    try std.testing.expect(worker.getHandler(&handlers, "worker-test-missing") == null);
}

test "executeTaskHandler runs the listed handler with the data and context" {
    const console_log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var timer_list = ziggy.timers.TimerList.init();
    defer arena.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.test_timestamp_provider.TestTimestampProvider = .{};
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "s", "task-7", .{ .context = null, .function = ignoreEvent }, 1);

    const outputs = try worker.executeTaskHandler(arena.allocator(), std.testing.io, timer_list.interface(), console_log, &handlers, "worker-test-echo", .{ .string = "hi" }, context.taskContext());
    try std.testing.expectEqualStrings("hi", outputs.object.get("echo").?.string);
    try std.testing.expectEqualStrings("task-7", outputs.object.get("taskId").?.string);
}

test "executeTaskHandler propagates handler errors" {
    const console_log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var timer_list = ziggy.timers.TimerList.init();
    defer arena.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.test_timestamp_provider.TestTimestampProvider = .{};
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "s", "t", .{ .context = null, .function = ignoreEvent }, 1);

    try std.testing.expectError(error.Thrown, worker.executeTaskHandler(arena.allocator(), std.testing.io, timer_list.interface(), console_log, &handlers, "worker-test-throw", .null, context.taskContext()));
    try std.testing.expectEqualStrings("Handler failed", errors.lastErrorMessage());
}

test "executeTaskHandler throws when the list has no handler for the type, naming the listed types in order" {
    const console_log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var timer_list = ziggy.timers.TimerList.init();
    defer arena.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.test_timestamp_provider.TestTimestampProvider = .{};
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "s", "t", .{ .context = null, .function = ignoreEvent }, 1);

    try std.testing.expectError(error.Thrown, worker.executeTaskHandler(arena.allocator(), std.testing.io, timer_list.interface(), console_log, &handlers, "worker-test-nope", .null, context.taskContext()));
    try std.testing.expectEqualStrings("No handler registered for task type: worker-test-nope. Available handlers: worker-test-one, worker-test-echo, worker-test-throw, worker-test-available", errors.lastErrorMessage());
}
