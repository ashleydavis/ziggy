//
// Tests of the queue backend: handlers written against the task queue run on the core's workers when the app lists them in its
// `.tasks`, code written against IQueueBackend and TaskQueue works on a worker and on the worker pool, and the callbacks TaskQueue is
// built on fire.
//

const std = @import("std");
const ziggy = @import("ziggy");
const task_queue = @import("ziggy").task_queue;
const ziggy_log = ziggy.log;
const helpers = @import("helpers.zig");

const types = task_queue.types;
const getQueueBackend = task_queue.queue_backend.getQueueBackend;
const TaskQueue = task_queue.task_queue.TaskQueue;
const MockWorkerPool = task_queue.mock_worker_pool.MockWorkerPool;
const Timers = ziggy.timers.Timers;
const TimerList = ziggy.timers.TimerList;

fn echoHandler(allocator: std.mem.Allocator, io: std.Io, timers: ziggy.timers.Timers, log: ziggy_log.log.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = timers;
    var event: std.json.ObjectMap = .empty;
    try event.put(allocator, "type", .{ .string = "registered-hello" });
    context.sendEvent(io, allocator, log, .{ .object = event });
    var outputs: std.json.ObjectMap = .empty;
    try outputs.put(allocator, "taskId", .{ .string = context.taskId });
    try outputs.put(allocator, "echo", data);
    return .{ .object = outputs };
}

fn waitForCancelHandler(allocator: std.mem.Allocator, io: std.Io, timers: ziggy.timers.Timers, log: ziggy_log.log.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = timers;
    _ = data;
    while (!context.isCancelled(io, allocator)) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Cancelled;
}

fn childHandler(allocator: std.mem.Allocator, io: std.Io, timers: ziggy.timers.Timers, log: ziggy_log.log.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
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
fn addUpChild(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.log.ILog, result: types.ITaskResult) anyerror!void {
    _ = log;
    _ = io;
    _ = allocator;
    const sum: *i64 = @ptrCast(@alignCast(context.?));
    sum.* += result.outputs.?.integer;
}

fn parentHandler(allocator: std.mem.Allocator, io: std.Io, timers: ziggy.timers.Timers, log: ziggy_log.log.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    const console_log = ziggy_log.mute_log.MuteLog.init();
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
    const console_log = ziggy_log.mute_log.MuteLog.init();
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
const queue_tasks = task_queue.mock_worker_pool.handlers(.{
    .@"registered-echo" = echoHandler,
    .@"registered-wait" = waitForCancelHandler,
    .@"registered-parent" = parentHandler,
    .@"registered-child" = childHandler,
    .@"queue-through-backend" = queueThroughBackendTask,
    .@"child-report" = childReportTask,
});

//
// The app of these tests: the helpers' app with the task types above as well.
//
const backend_app = registered: {
    var registered = helpers.app;
    registered.tasks = &(helpers.task_handlers ++ queue_tasks[0..queue_tasks.len].*);
    break :registered registered;
};

fn createCore(native_app: *helpers.FakeNativeApp, worker_threads: u32) !void {
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(worker_threads, 4), backend_app);
}

fn addTask(native_app: *helpers.FakeNativeApp, id: []const u8, task_type: []const u8, source: []const u8, data: []const u8, priority: []const u8) !void {
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
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "r1", "registered-echo", "s", "{\"a\":1}", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"task-event\",\"data\":{\"taskId\":\"r1\",\"source\":\"s\",\"data\":{\"type\":\"registered-hello\"}}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"outputs\":{\"taskId\":\"r1\",\"echo\":{\"a\":1}},\"type\":\"registered-echo\",\"inputs\":{\"a\":1}");
}

test "a handler written against the task queue sees its task cancelled when the source is cancelled" {
    var native_app: helpers.FakeNativeApp = undefined;
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
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app, 4);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "p1", "registered-parent", "s", "null", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"task-completed\",\"data\":{\"taskId\":\"p1\",\"result\":{\"taskId\":\"p1\",\"status\":\"succeeded\",\"outputs\":6,");
}

test "a task queued through the backend by a running task runs at that task's priority" {
    var native_app: helpers.FakeNativeApp = undefined;
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

//
// Records what the callbacks are given, for the tests to look at.
//
const Recorder = struct {
    // One line per call, as "kind|taskId|detail".
    lines: std.ArrayList([]u8) = .empty,

    fn record(self: *Recorder, line: []u8) void {
        self.lines.append(std.testing.allocator, line) catch @panic("out of memory");
    }

    fn deinit(self: *Recorder) void {
        for (self.lines.items) |line| {
            std.testing.allocator.free(line);
        }
        self.lines.deinit(std.testing.allocator);
    }

    fn count(self: *Recorder, prefix: []const u8) usize {
        var found: usize = 0;
        for (self.lines.items) |line| {
            if (std.mem.startsWith(u8, line, prefix)) {
                found += 1;
            }
        }
        return found;
    }

    //
    // Reads the pool's messages until a line starting with the prefix has been recorded.
    //
    fn waitFor(self: *Recorder, pool: *MockWorkerPool, timers: Timers, prefix: []const u8) void {
        const console_log = ziggy_log.mute_log.MuteLog.init();
        while (self.count(prefix) == 0) {
            pool.waitForMessage(std.testing.io, std.testing.allocator, timers, console_log);
        }
    }

    fn onComplete(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.log.ILog, result: types.ITaskResult) anyerror!void {
        _ = log;
        _ = io;
        _ = allocator;
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        const outputs = if (result.outputs) |value| try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{}) else try std.testing.allocator.dupe(u8, "none");
        defer std.testing.allocator.free(outputs);
        const inputs = try std.json.Stringify.valueAlloc(std.testing.allocator, result.inputs, .{});
        defer std.testing.allocator.free(inputs);
        self.record(try std.fmt.allocPrint(std.testing.allocator, "complete|{s}|{s}|{s}|{s}|{s}|{s}", .{ result.taskId, result.type, result.status.toString(), result.errorMessage orelse "no error", outputs, inputs }));
    }

    fn onEvent(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.log.ILog, data: types.ITaskEventData) anyerror!void {
        _ = log;
        _ = io;
        _ = allocator;
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        const event = try std.json.Stringify.valueAlloc(std.testing.allocator, data.event, .{});
        defer std.testing.allocator.free(event);
        self.record(try std.fmt.allocPrint(std.testing.allocator, "event|{s}|{s}", .{ data.taskId, event }));
    }

    fn onTypedEvent(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.log.ILog, data: types.ITaskEventData) anyerror!void {
        _ = log;
        _ = io;
        _ = allocator;
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        self.record(try std.fmt.allocPrint(std.testing.allocator, "typed|{s}", .{data.taskId}));
    }

    fn onAdded(context: ?*anyopaque, allocator: std.mem.Allocator, log: ziggy.log.log.ILog, task_id: []const u8) void {
        _ = log;
        _ = allocator;
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        self.record(std.fmt.allocPrint(std.testing.allocator, "added|{s}", .{task_id}) catch @panic("out of memory"));
    }

    fn onCancelled(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        _ = io;
        _ = allocator;
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        self.record(std.fmt.allocPrint(std.testing.allocator, "cancelled|", .{}) catch @panic("out of memory"));
    }
};

//
// Makes a pool of workers, run by the calling thread, with the task types of these tests.
//
fn createPool(workers: usize) !*MockWorkerPool {
    return try MockWorkerPool.init(std.testing.allocator, workers, .{
        .sessionId = "queue-backend-test",
    }, &queue_tasks[0..queue_tasks.len].*);
}

test "the completion callback gets the task's type, input, status and outputs, and stops after it is unsubscribed" {
    const console_log = ziggy_log.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    const pool = try createPool(2);
    defer pool.deinit(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const backend = pool.queueBackend();
    const unsubscribe = try backend.onTaskComplete(std.testing.allocator, .{
        .context = &recorder,
        .function = Recorder.onComplete,
    });
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(std.testing.allocator);
    try data.put(std.testing.allocator, "a", .{ .integer = 1 });
    const first = try backend.addTask(std.testing.allocator, std.testing.io, console_log, "registered-echo", .{ .object = data }, "s", "c1", null);
    defer std.testing.allocator.free(first);
    recorder.waitFor(pool, timer_list.interface(), "complete|c1|registered-echo|succeeded|no error|{\"taskId\":\"c1\",\"echo\":{\"a\":1}}|{\"a\":1}");
    unsubscribe.call(std.testing.allocator);
    const second = try backend.addTask(std.testing.allocator, std.testing.io, console_log, "registered-echo", .{ .object = data }, "s", "c2", null);
    defer std.testing.allocator.free(second);
    while (pool.pool.isBusy()) {
        pool.waitForMessage(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    }
    try std.testing.expectEqual(@as(usize, 0), recorder.count("complete|c2"));
}

test "a task that fails or is cancelled while running is reported as failed, and one cancelled while queued is not reported" {
    const console_log = ziggy_log.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    const pool = try createPool(1);
    defer pool.deinit(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const backend = pool.queueBackend();
    const unsubscribe = try backend.onTaskComplete(std.testing.allocator, .{
        .context = &recorder,
        .function = Recorder.onComplete,
    });
    defer unsubscribe.call(std.testing.allocator);
    const running = try backend.addTask(std.testing.allocator, std.testing.io, console_log, "registered-wait", .null, "gone", "running", null);
    defer std.testing.allocator.free(running);
    // The first task is sent to the worker once the worker reports it is ready.
    while (pool.pool.pending_tasks.items.len > 0) {
        pool.waitForMessage(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    }
    const queued = try backend.addTask(std.testing.allocator, std.testing.io, console_log, "registered-echo", .null, "gone", "queued", null);
    defer std.testing.allocator.free(queued);
    backend.cancelTasks(std.testing.io, std.testing.allocator, console_log, "gone");
    recorder.waitFor(pool, timer_list.interface(), "complete|running|registered-wait|failed|Cancelled|none|null");
    try std.testing.expectEqual(@as(usize, 0), recorder.count("complete|queued"));
}

test "event callbacks get the events of a type, and every event" {
    const console_log = ziggy_log.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    const pool = try createPool(2);
    defer pool.deinit(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const backend = pool.queueBackend();
    const any = try backend.onAnyTaskEvent(std.testing.allocator, .{
        .context = &recorder,
        .function = Recorder.onEvent,
    });
    defer any.call(std.testing.allocator);
    const typed = try backend.onTaskEvent(std.testing.allocator, "registered-hello", .{
        .context = &recorder,
        .function = Recorder.onTypedEvent,
    });
    defer typed.call(std.testing.allocator);
    const other = try backend.onTaskEvent(std.testing.allocator, "something-else", .{
        .context = &recorder,
        .function = Recorder.onTypedEvent,
    });
    defer other.call(std.testing.allocator);
    const id = try backend.addTask(std.testing.allocator, std.testing.io, console_log, "registered-echo", .null, "s", "m1", null);
    defer std.testing.allocator.free(id);
    recorder.waitFor(pool, timer_list.interface(), "event|m1|{\"type\":\"registered-hello\"}");
    recorder.waitFor(pool, timer_list.interface(), "typed|m1");
    while (pool.pool.isBusy()) {
        pool.waitForMessage(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    }
    try std.testing.expectEqual(@as(usize, 1), recorder.count("typed|"));
}

test "callbacks for a source fire when a task is added under it and when the source is cancelled" {
    const console_log = ziggy_log.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    const pool = try createPool(2);
    defer pool.deinit(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const backend = pool.queueBackend();
    const added = try backend.onTaskAdded(std.testing.allocator, "watched", .{
        .context = &recorder,
        .function = Recorder.onAdded,
    });
    defer added.call(std.testing.allocator);
    const cancelled = try backend.onTasksCancelled(std.testing.allocator, "watched", .{
        .context = &recorder,
        .function = Recorder.onCancelled,
    });
    defer cancelled.call(std.testing.allocator);
    const unwatched_id = try backend.addTask(std.testing.allocator, std.testing.io, console_log, "registered-echo", .null, "unwatched", "u1", null);
    defer std.testing.allocator.free(unwatched_id);
    const id = try backend.addTask(std.testing.allocator, std.testing.io, console_log, "registered-echo", .null, "watched", "w1", null);
    defer std.testing.allocator.free(id);
    try std.testing.expectEqual(@as(usize, 1), recorder.count("added|w1"));
    try std.testing.expectEqual(@as(usize, 0), recorder.count("added|u1"));
    backend.cancelTasks(std.testing.io, std.testing.allocator, console_log, "unwatched");
    try std.testing.expectEqual(@as(usize, 0), recorder.count("cancelled|"));
    backend.cancelTasks(std.testing.io, std.testing.allocator, console_log, "watched");
    try std.testing.expectEqual(@as(usize, 1), recorder.count("cancelled|"));
}

