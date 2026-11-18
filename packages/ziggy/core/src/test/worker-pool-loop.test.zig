//
// Tests of the loop of a WorkerPool made with create, which runs tasks on Ziggy's workers for a program or a test with no Ziggy
// core. Each test makes a pool on the test's thread, as its main thread, queues tasks through the pool's IQueueBackend and reads
// what the callbacks of that backend are given while the test waits through the pool. The tests whose pool abandons a worker at a
// task's timeout make it with an allocator that does not count leaks, because an abandoned worker's memory is never freed.
//

const std = @import("std");
const ziggy = @import("ziggy");
const task_queue = ziggy.task_queue;
const logging = ziggy.log;
const test_tasks = @import("test-tasks.zig");

const types = task_queue.types;
const WorkerPool = ziggy.worker_pool.WorkerPool;
const Timers = ziggy.timers.Timers;
const TimerList = ziggy.timers.TimerList;
const errors = ziggy.utils.errors;

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
    fn waitFor(self: *Recorder, pool: *WorkerPool, timers: Timers, prefix: []const u8) void {
        const console_log = logging.mute_log.MuteLog.init();
        while (self.count(prefix) == 0) {
            pool.waitForMessage(std.testing.io, std.testing.allocator, timers, console_log);
        }
    }

    fn onComplete(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, result: types.ITaskResult) anyerror!void {
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

    fn onEvent(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, data: types.ITaskEventData) anyerror!void {
        _ = log;
        _ = io;
        _ = allocator;
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        const event = try std.json.Stringify.valueAlloc(std.testing.allocator, data.event, .{});
        defer std.testing.allocator.free(event);
        self.record(try std.fmt.allocPrint(std.testing.allocator, "event|{s}|{s}", .{ data.taskId, event }));
    }

    fn onTypedEvent(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, data: types.ITaskEventData) anyerror!void {
        _ = log;
        _ = io;
        _ = allocator;
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        self.record(try std.fmt.allocPrint(std.testing.allocator, "typed|{s}", .{data.taskId}));
    }

    fn onAdded(context: ?*anyopaque, allocator: std.mem.Allocator, log: ziggy.log.ILog, task_id: []const u8) void {
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
// The task types of these tests: the two written against the task queue above, and the core tests' own, among them "sleep", which
// sleeps for the milliseconds its data gives.
//
const queue_tasks = [_]ziggy.task_runner.TaskHandlerEntry{
    .{ .name = "registered-echo", .handler = ziggy.task_runner.fromQueueHandler(echoHandler) },
    .{ .name = "registered-wait", .handler = ziggy.task_runner.fromQueueHandler(waitForCancelHandler) },
} ++ test_tasks.task_handlers;

//
// Gives the text of a failed task's error: the message the handler recorded (the task queue's throwError), or the error's name.
//
fn describeError(err: anyerror) ?[]const u8 {
    const message = errors.errorMessage(err);
    if (message.len == 0) {
        return null;
    }
    return message;
}

//
// Makes a pool of workers, run by the calling thread, with the task types of these tests, allocated with the allocator, and the
// task timeout given, or none.
//
fn createPoolWith(allocator: std.mem.Allocator, workers: u32, task_timeout_ms: ?u64) !*WorkerPool {
    return try WorkerPool.create(allocator, .{
        .max_workers = workers,
        .tasks = &queue_tasks,
        .describe_error = describeError,
        .worker_options = .{
            .workerId = 0,
            .sessionId = "queue-backend-test",
            .maxConcurrentChildTasks = 2,
        },
        .task_timeout_ms = task_timeout_ms,
    });
}

//
// Makes a pool of workers, run by the calling thread, with the task types of these tests and no task timeout.
//
fn createPool(workers: u32) !*WorkerPool {
    return try createPoolWith(std.testing.allocator, workers, null);
}

test "the completion callback gets the task's type, input, status and outputs, and stops after it is unsubscribed" {
    const console_log = logging.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    const pool = try createPool(2);
    defer pool.destroy(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
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
    while (pool.isBusy()) {
        pool.waitForMessage(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    }
    try std.testing.expectEqual(@as(usize, 0), recorder.count("complete|c2"));
}

test "a task that fails or is cancelled while running is reported as failed, and one cancelled while queued is not reported" {
    const console_log = logging.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    const pool = try createPool(1);
    defer pool.destroy(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
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
    while (pool.pending_tasks.items.len > 0) {
        pool.waitForMessage(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    }
    const queued = try backend.addTask(std.testing.allocator, std.testing.io, console_log, "registered-echo", .null, "gone", "queued", null);
    defer std.testing.allocator.free(queued);
    backend.cancelTasks(std.testing.io, std.testing.allocator, console_log, "gone");
    recorder.waitFor(pool, timer_list.interface(), "complete|running|registered-wait|failed|Cancelled|none|null");
    try std.testing.expectEqual(@as(usize, 0), recorder.count("complete|queued"));
}

test "event callbacks get the events of a type, and every event" {
    const console_log = logging.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    const pool = try createPool(2);
    defer pool.destroy(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
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
    while (pool.isBusy()) {
        pool.waitForMessage(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    }
    try std.testing.expectEqual(@as(usize, 1), recorder.count("typed|"));
}

test "callbacks for a source fire when a task is added under it and when the source is cancelled" {
    const console_log = logging.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    const pool = try createPool(2);
    defer pool.destroy(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
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

//
// Goal: a task that runs past the pool's timeout is failed while the owner waits through waitForMessage, rather than left to finish.
// Method: give a pool a 50 ms timeout, queue a task that sleeps for 300 ms and wait through the pool until the task ends, then look at
// how it ended. Without the timeout the task would end as succeeded once its sleep was over.
//
test "waitForMessage fails a task that runs past its timeout while it waits" {
    const console_log = logging.mute_log.MuteLog.init();
    const pool_allocator = std.heap.smp_allocator;
    var timer_list = TimerList.init();
    const pool = try createPoolWith(pool_allocator, 1, 50);
    defer pool.destroy(std.testing.io, pool_allocator, timer_list.interface(), console_log);
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const backend = pool.queueBackend();
    _ = try backend.onTaskComplete(pool_allocator, .{
        .context = &recorder,
        .function = Recorder.onComplete,
    });
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(std.testing.allocator);
    try data.put(std.testing.allocator, "ms", .{ .integer = 300 });
    const id = try backend.addTask(pool_allocator, std.testing.io, console_log, "sleep", .{ .object = data }, "s", "slow", null);
    defer pool_allocator.free(id);
    while (recorder.count("complete|slow|") == 0) {
        pool.waitForMessage(std.testing.io, pool_allocator, timer_list.interface(), console_log);
    }
    try std.testing.expectEqual(@as(usize, 1), recorder.count("complete|slow|sleep|failed|Task timeout|none|{\"ms\":300}"));
}

//
// Goal: drainMessages hands the pool what the workers have already sent and returns without waiting for more.
// Method: drain an idle pool, which must return at once, then queue a task and drain the pool every 5 ms until the task's end is
// reported, for no more than ten seconds.
//
test "drainMessages hands the pool the messages already sent without waiting for more" {
    const console_log = logging.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    const pool = try createPool(1);
    defer pool.destroy(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const backend = pool.queueBackend();
    const unsubscribe = try backend.onTaskComplete(std.testing.allocator, .{
        .context = &recorder,
        .function = Recorder.onComplete,
    });
    defer unsubscribe.call(std.testing.allocator);
    pool.drainMessages(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    const id = try backend.addTask(std.testing.allocator, std.testing.io, console_log, "registered-echo", .null, "s", "d1", null);
    defer std.testing.allocator.free(id);
    var turns: u32 = 0;
    while (recorder.count("complete|d1|") == 0 and turns < 2000) : (turns += 1) {
        pool.drainMessages(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
        try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    try std.testing.expectEqual(@as(usize, 1), recorder.count("complete|d1|registered-echo|succeeded|"));
}

//
// Goal: a pool that may start no worker leaves its task waiting rather than running or failing it.
// Method: queue a task on a pool whose maximum is 0 workers, give it 100 ms, hand it what has been sent, and check nothing completed
// and no worker was started. The task is cancelled at the end so the pool is not busy when it is freed.
//
test "a pool whose maximum is 0 workers leaves its task pending" {
    const console_log = logging.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    const pool = try createPool(0);
    defer pool.destroy(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const backend = pool.queueBackend();
    const unsubscribe = try backend.onTaskComplete(std.testing.allocator, .{
        .context = &recorder,
        .function = Recorder.onComplete,
    });
    defer unsubscribe.call(std.testing.allocator);
    const id = try backend.addTask(std.testing.allocator, std.testing.io, console_log, "registered-echo", .null, "source", "task-4", null);
    defer std.testing.allocator.free(id);
    try std.testing.io.sleep(.fromMilliseconds(100), .awake);
    pool.drainMessages(std.testing.io, std.testing.allocator, timer_list.interface(), console_log);
    try std.testing.expectEqual(@as(usize, 0), recorder.count("complete|"));
    try std.testing.expectEqual(@as(usize, 0), pool.workers.items.len);
    backend.cancelTasks(std.testing.io, std.testing.allocator, console_log, "source");
}

//
// Goal: a worker abandoned at its task's timeout can still post once the pool is freed, and what it posts goes nowhere.
// Method: time out a task that sleeps for 300 ms, free the pool, then wait past the end of the sleep, when the abandoned worker posts
// the task's end, and check the queue the pool left behind is closed and holds nothing.
//
test "a worker abandoned at its timeout can still send once the pool is gone, and what it sends is dropped" {
    const console_log = logging.mute_log.MuteLog.init();
    const pool_allocator = std.heap.smp_allocator;
    var timer_list = TimerList.init();
    const pool = try createPoolWith(pool_allocator, 1, 50);
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const backend = pool.queueBackend();
    _ = try backend.onTaskComplete(pool_allocator, .{
        .context = &recorder,
        .function = Recorder.onComplete,
    });
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(std.testing.allocator);
    try data.put(std.testing.allocator, "ms", .{ .integer = 300 });
    const id = try backend.addTask(pool_allocator, std.testing.io, console_log, "sleep", .{ .object = data }, "source", "slow-task", null);
    defer pool_allocator.free(id);
    while (recorder.count("complete|slow-task|") == 0) {
        pool.waitForMessage(std.testing.io, pool_allocator, timer_list.interface(), console_log);
    }
    try std.testing.expect(pool.hasAbandonedWorkers());
    const queue = pool.main_queue;
    pool.destroy(std.testing.io, pool_allocator, timer_list.interface(), console_log);

    // The pool kept its queue for the abandoned worker and closed it, so the end the worker sends once its task has run its 300 ms
    // is dropped.
    try std.testing.expect(queue.isClosed(std.testing.io));
    try std.testing.io.sleep(.fromMilliseconds(600), .awake);
    try std.testing.expect(queue.tryTake(std.testing.io, std.testing.allocator) == null);
}

