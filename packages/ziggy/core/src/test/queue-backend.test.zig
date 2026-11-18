//
// Tests of the queue backend on the core: handlers written against the task queue run on the core's workers when the app lists them
// in its `.tasks`, and code written against IQueueBackend and TaskQueue works on a worker. The callbacks of the backend a WorkerPool
// gives are tested in worker-pool-loop.test.zig.
//

const std = @import("std");
const ziggy = @import("ziggy");
const task_queue = @import("ziggy").task_queue;
const logging = ziggy.log;
const test_app = @import("test-app.zig");
const test_tasks = @import("test-tasks.zig");
const FakeNativeApp = ziggy.fake_native_app.FakeNativeApp;

const types = task_queue.types;
const getQueueBackend = task_queue.queue_backend.getQueueBackend;
const TaskQueue = task_queue.task_queue.TaskQueue;
const Timers = ziggy.timers.Timers;

fn echoHandler(allocator: std.mem.Allocator, io: std.Io, timers: ziggy.timers.Timers, log: logging.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = timers;
    var event: std.json.ObjectMap = .empty;
    try event.put(allocator, "type", .{ .string = "registered-hello" });
    context.sendEvent(io, allocator, log, .{ .object = event });
    var outputs: std.json.ObjectMap = .empty;
    try outputs.put(allocator, "taskId", .{ .string = context.taskId });
    try outputs.put(allocator, "echo", data);
    return .{ .object = outputs };
}

fn waitForCancelHandler(allocator: std.mem.Allocator, io: std.Io, timers: ziggy.timers.Timers, log: logging.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = timers;
    _ = data;
    while (!context.isCancelled(io, allocator)) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Cancelled;
}

fn childHandler(allocator: std.mem.Allocator, io: std.Io, timers: ziggy.timers.Timers, log: logging.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = timers;
    _ = allocator;
    _ = io;
    _ = context;
    return data;
}

//
// Adds up the outputs of the children a parent queued, as its completion callback is given them.
//
fn addUpChild(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, result: types.ITaskResult) anyerror!void {
    _ = log;
    _ = io;
    _ = allocator;
    const sum: *i64 = @ptrCast(@alignCast(context.?));
    sum.* += result.outputs.?.integer;
}

fn parentHandler(allocator: std.mem.Allocator, io: std.Io, timers: ziggy.timers.Timers, log: logging.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    const console_log = logging.mute_log.MuteLog.init();
    _ = log;
    _ = data;
    const queue = try TaskQueue.init(allocator, context.uuidGenerator, "registered-parent");
    defer queue.deinit(io, allocator, console_log);
    var sum: i64 = 0;
    _ = try queue.onTaskComplete(allocator, .{
        .context = &sum,
        .function = addUpChild,
    });
    var index: i64 = 1;
    while (index <= 3) : (index += 1) {
        _ = try queue.addTask(io, allocator, console_log, "registered-child", .{ .integer = index }, null, null);
    }
    try queue.awaitAllTasks(io, allocator, timers, console_log);
    return .{ .integer = sum };
}

//
// A task that queues a task through its worker's backend, as a handler written against task-queue does, and returns which task it
// queued.
//
fn queueThroughBackendTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, payload: std.json.Value) ![]const u8 {
    const console_log = logging.mute_log.MuteLog.init();
    _ = services;
    _ = timers;
    _ = context;
    _ = payload;
    const backend = try getQueueBackend();
    return try backend.addTask(allocator, io, console_log, "child-report", .null, "backend-source", null, null);
}

//
// The child the task above queues.
//
fn childReportTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, payload: std.json.Value) ![]const u8 {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = payload;
    return "child ran";
}

//
// The task types of these tests written against the task queue, as an app lists them.
//
const queue_tasks = [_]ziggy.task_runner.TaskHandlerEntry{
    .{ .name = "registered-echo", .handler = ziggy.task_runner.fromQueueHandler(echoHandler) },
    .{ .name = "registered-wait", .handler = ziggy.task_runner.fromQueueHandler(waitForCancelHandler) },
    .{ .name = "registered-parent", .handler = ziggy.task_runner.fromQueueHandler(parentHandler) },
    .{ .name = "registered-child", .handler = ziggy.task_runner.fromQueueHandler(childHandler) },
    .{ .name = "queue-through-backend", .handler = ziggy.task_runner.wrapTask("queue-through-backend", queueThroughBackendTask) },
    .{ .name = "child-report", .handler = ziggy.task_runner.wrapTask("child-report", childReportTask) },
};

//
// The app of these tests: the tests' app (test-app.zig) with the task types above as well.
//
const backend_app = registered: {
    var registered = test_app.app;
    registered.tasks = &(test_tasks.task_handlers ++ queue_tasks[0..queue_tasks.len].*);
    break :registered registered;
};

fn createCore(native_app: *FakeNativeApp, worker_threads: u32) !void {
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(worker_threads, 4), backend_app);
}

fn addTask(native_app: *FakeNativeApp, id: []const u8, task_type: []const u8, source: []const u8, data: []const u8, priority: []const u8) !void {
    const message = try ziggy.json.stringify(std.testing.allocator, .{
        .kind = "system",
        .name = "add-task",
        .data = .{
            .taskId = id,
            .taskType = task_type,
            .source = source,
            .data = ziggy.json.Raw{ .text = data },
            .priority = priority,
        },
    });
    defer std.testing.allocator.free(message);
    try native_app.send(std.testing.io, std.testing.allocator, message);
}

test "a handler written against the task queue runs on a worker, sends events and returns its outputs" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "r1", "registered-echo", "s", "{\"a\":1}", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"task-event\",\"data\":{\"taskId\":\"r1\",\"source\":\"s\",\"data\":{\"type\":\"registered-hello\"}}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"outputs\":{\"taskId\":\"r1\",\"echo\":{\"a\":1}},\"type\":\"registered-echo\",\"inputs\":{\"a\":1}");
}

test "a handler written against the task queue sees its task cancelled when the source is cancelled" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "w1", "registered-wait", "wait-source", "null", "background");
    ziggy.fake_native_app.sleepMs(std.testing.io, 20);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"cancel-tasks\",\"data\":\"wait-source\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"failed\",\"error\":{\"message\":\"Cancelled\"},\"errorMessage\":\"Cancelled\"");
}

test "a handler written against the task queue queues child tasks with TaskQueue on its worker and awaits them" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app, 4);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "p1", "registered-parent", "s", "null", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"task-completed\",\"data\":{\"taskId\":\"p1\",\"result\":{\"taskId\":\"p1\",\"status\":\"succeeded\",\"outputs\":6,");
}

test "a task queued through the backend by a running task runs at that task's priority" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    // One worker, so the tasks run one at a time, in the order of the queue. A spin task holds the worker until its source is
    // cancelled, so the tasks queued after it wait in the queue in a known order.
    try createCore(&native_app, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const spin = "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"hold\",\"taskType\":\"spin\",\"source\":\"blocker\",\"data\":null,\"priority\":\"background\"}}";
    const release = "{\"kind\":\"system\",\"name\":\"cancel-tasks\",\"data\":\"blocker\"}";
    // An interactive parent's child goes ahead of the background task already waiting.
    native_app.sendMessage(std.testing.allocator, spin);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"q1\",\"taskType\":\"queue-through-backend\",\"source\":\"s\",\"data\":null,\"priority\":\"interactive\"}}");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"b1\",\"taskType\":\"quick\",\"source\":\"s\",\"data\":null,\"priority\":\"background\"}}");
    native_app.sendMessage(std.testing.allocator, release);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"b1\",\"status\":\"succeeded\"");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"succeeded\",\"outputs\":\"child ran\",\"type\":\"child-report\"");
    const child_end = native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"type\":\"child-report\"").?;
    const waiting_end = native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"b1\",\"status\":\"succeeded\"").?;
    try std.testing.expect(child_end < waiting_end);
    // A background parent's child goes behind the background task already waiting.
    try native_app.handled(std.testing.io, std.testing.allocator);
    native_app.removeContaining(std.testing.io, std.testing.allocator, "\"type\":\"child-report\"");
    native_app.sendMessage(std.testing.allocator, spin);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"q2\",\"taskType\":\"queue-through-backend\",\"source\":\"s\",\"data\":null,\"priority\":\"background\"}}");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"b2\",\"taskType\":\"quick\",\"source\":\"s\",\"data\":null,\"priority\":\"background\"}}");
    native_app.sendMessage(std.testing.allocator, release);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"succeeded\",\"outputs\":\"child ran\",\"type\":\"child-report\"");
    const second_child_end = native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"type\":\"child-report\"").?;
    const second_waiting_end = native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"b2\",\"status\":\"succeeded\"").?;
    try std.testing.expect(second_waiting_end < second_child_end);
}
