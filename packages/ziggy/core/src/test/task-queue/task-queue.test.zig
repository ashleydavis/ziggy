//
// The task queue's tests. The workers share nothing with the test's thread: what a task did comes back to the test as its result and
// its events, and a task that holds its worker is let go by a cancel of its release source, which reaches every worker as a message.
//

const std = @import("std");
const task_queue_zig = @import("ziggy").task_queue;
const utils = ziggy.utils;
const logging = ziggy.log;
const TaskQueue = task_queue_zig.task_queue.TaskQueue;
const types = task_queue_zig.types;
const TaskStatus = types.TaskStatus;
const TaskPriority = types.TaskPriority;
const ITaskResult = types.ITaskResult;
const ITaskContext = types.ITaskContext;
const ziggy = @import("ziggy");
const Timers = ziggy.timers.Timers;
const TimerList = ziggy.timers.TimerList;
const setQueueBackend = task_queue_zig.queue_backend.setQueueBackend;
const getQueueBackend = task_queue_zig.queue_backend.getQueueBackend;
const IQueueBackend = task_queue_zig.queue_backend.IQueueBackend;
const MockWorkerPool = task_queue_zig.mock_worker_pool.MockWorkerPool;
const errors = utils.errors;

//
// The source whose cancel lets the tasks held by `slowBlockedHandler` go.
//
const release_source = "test-release";

//
// The source whose cancel lets the tasks held by `secondSlowBlockedHandler` go.
//
const second_release_source = "test-second-release";

//
// The task types the pools of these tests run, each with its handler.
//
const test_task_types = [_]ziggy.task_runner.TaskHandlerEntry{
    .{ .name = "test-task", .handler = ziggy.task_runner.fromQueueHandler(doneHandler) },
    .{ .name = "slow-task", .handler = ziggy.task_runner.fromQueueHandler(slowBlockedHandler) },
    .{ .name = "second-slow-task", .handler = ziggy.task_runner.fromQueueHandler(secondSlowBlockedHandler) },
    .{ .name = "counting-task", .handler = ziggy.task_runner.fromQueueHandler(countingHandler) },
    .{ .name = "slow-counting-task", .handler = ziggy.task_runner.fromQueueHandler(slowCountingHandler) },
    .{ .name = "recording-task", .handler = ziggy.task_runner.fromQueueHandler(recordingHandler) },
    .{ .name = "echo-task", .handler = ziggy.task_runner.fromQueueHandler(echoHandler) },
    .{ .name = "event-task", .handler = ziggy.task_runner.fromQueueHandler(eventSendingHandler) },
    .{ .name = "success-task", .handler = ziggy.task_runner.fromQueueHandler(doneHandler) },
    .{ .name = "fail-task", .handler = ziggy.task_runner.fromQueueHandler(failHandler) },
    .{ .name = "ordered-task", .handler = ziggy.task_runner.fromQueueHandler(orderedTaskHandler) },
    .{ .name = "progress-task", .handler = ziggy.task_runner.fromQueueHandler(progressHandler) },
    .{ .name = "custom-error", .handler = ziggy.task_runner.fromQueueHandler(customErrorHandler) },
    .{ .name = "throw-string", .handler = ziggy.task_runner.fromQueueHandler(plainZigErrorHandler) },
};

//
// The context every task of these tests shares.
//
const test_base_context: task_queue_zig.mock_worker_pool.IBaseContext = .{
    .sessionId = "test-session",
};

//
// What each test runs on: a pool of workers, registered as the test thread's backend, and a queue of the source "test" on it.
//
const Setup = struct {
    // The in-process backend.
    backend: *MockWorkerPool,
    // The queue under test (source "test").
    queue: *TaskQueue,

    //
    // beforeEach: creates a MockWorkerPool(maxConcurrent), registers it and creates the queue, with the test thread's allocator.
    //
    fn init(allocator: std.mem.Allocator, maxConcurrent: usize) !Setup {
        const backend = try MockWorkerPool.init(allocator, maxConcurrent, test_base_context, &test_task_types);
        setQueueBackend(backend.queueBackend());
        var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
        return .{
            .backend = backend,
            .queue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "test"),
        };
    }

    //
    // afterEach: shuts the queue down, waits for the backend's tasks and frees everything.
    //
    fn deinit(self: Setup, io: std.Io, allocator: std.mem.Allocator, timers: Timers) void {
        const console_log = logging.mute_log.MuteLog.init();
        self.queue.deinit(io, allocator, console_log);
        setQueueBackend(null);
        self.backend.deinit(io, allocator, timers, console_log);
    }

    //
    // Reads the pool's messages until every task has been sent to a worker. A release reaches only the workers already sent their task,
    // because a worker's messages are read in the order they were sent.
    //
    fn waitUntilDispatched(self: Setup, io: std.Io, allocator: std.mem.Allocator, timers: Timers) void {
        const console_log = logging.mute_log.MuteLog.init();
        while (self.backend.pool.pending_tasks.items.len > 0) {
            self.backend.waitForMessage(io, allocator, timers, console_log);
        }
    }

    //
    // Reads the pool's messages until no task is queued or running, so every callback that is going to run has run.
    //
    fn waitUntilIdle(self: Setup, io: std.Io, allocator: std.mem.Allocator, timers: Timers) void {
        const console_log = logging.mute_log.MuteLog.init();
        while (self.backend.pool.isBusy()) {
            self.backend.waitForMessage(io, allocator, timers, console_log);
        }
    }
};

//
// Parses JSON text into a task data value.
//
fn json(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// The current time in milliseconds (Date.now()).
//
fn nowMs() i64 {
    return std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
}

//
// Where a held task is: let go, or out of time.
//
const Hold = struct {
    // Set by the cancel of the release source.
    released: bool,
    // Set when no cancel came in time.
    timed_out: bool,
};

//
// The callback of the cancel of a release source: lets the held task go.
//
fn markReleased(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
    _ = io;
    _ = allocator;
    const hold: *Hold = @ptrCast(@alignCast(context.?));
    hold.released = true;
}

//
// The timer that gives up on a cancel that never comes, so a broken test fails instead of hanging the suite.
//
fn holdTimedOut(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, services: ?*const anyopaque) void {
    _ = services;
    _ = io;
    _ = allocator;
    _ = timers;
    const hold: *Hold = @ptrCast(@alignCast(context.?));
    hold.timed_out = true;
}

//
// Holds the task's worker, reading the worker's messages, until the test cancels the source given.
//
fn waitForRelease(allocator: std.mem.Allocator, io: std.Io, timers: Timers, source: []const u8) !void {
    const console_log = logging.mute_log.MuteLog.init();
    const backend = try getQueueBackend();
    var hold: Hold = .{
        .released = false,
        .timed_out = false,
    };
    const unsubscribe = try backend.onTasksCancelled(allocator, source, .{
        .context = &hold,
        .function = markReleased,
    });
    defer unsubscribe.call(allocator);
    const timer = try timers.setTimeout(io, .{
        .context = &hold,
        .function = holdTimedOut,
    }, 30_000);
    defer timers.clearTimeout(timer);
    while (!hold.released and !hold.timed_out) {
        backend.waitForMessage(io, allocator, timers, console_log);
    }
    if (!hold.released) {
        return error.ReleaseNeverCame;
    }
}

//
// Sends an event of the type "started" naming the task, so the test sees it has started.
//
fn sendStarted(allocator: std.mem.Allocator, io: std.Io, log: logging.ILog, context: ITaskContext, name: std.json.Value) !void {
    var event: std.json.ObjectMap = .empty;
    try event.put(allocator, "type", .{ .string = "started" });
    try event.put(allocator, "name", name);
    context.sendEvent(io, allocator, log, .{ .object = event });
}

//
// A handler that returns "done".
//
fn doneHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: logging.ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = allocator;
    _ = io;
    _ = timers;
    _ = data;
    _ = context;
    return .{ .string = "done" };
}

//
// A handler that holds its worker until the test cancels `release_source`, then returns "done".
//
fn slowBlockedHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: logging.ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = data;
    _ = context;
    try waitForRelease(allocator, io, timers, release_source);
    return .{ .string = "done" };
}

//
// A handler that holds its worker until the test cancels `second_release_source`, then returns "done".
//
fn secondSlowBlockedHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: logging.ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = data;
    _ = context;
    try waitForRelease(allocator, io, timers, second_release_source);
    return .{ .string = "done" };
}

//
// A handler that returns "Task <id> completed".
//
fn countingHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: logging.ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = io;
    _ = timers;
    _ = context;
    return .{ .string = try std.fmt.allocPrint(allocator, "Task {d} completed", .{data.object.get("id").?.integer}) };
}

//
// A handler that sleeps 100ms, then returns "done".
//
fn slowCountingHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: logging.ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = allocator;
    _ = timers;
    _ = data;
    _ = context;
    io.sleep(.fromMilliseconds(100), .awake) catch {};
    return .{ .string = "done" };
}

//
// A handler that fails.
//
fn failHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: logging.ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = allocator;
    _ = io;
    _ = timers;
    _ = data;
    _ = context;
    return errors.throwError("Failed", .{});
}

//
// A handler that sends "started" with its id, holds its worker until the test cancels `release_source` when its data requests it, and
// returns its id.
//
fn recordingHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: logging.ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    const id = data.object.get("id").?;
    try sendStarted(allocator, io, log, context, id);
    if (data.object.get("hold") != null) {
        try waitForRelease(allocator, io, timers, release_source);
    }
    return id;
}

//
// A handler that returns its data.
//
fn echoHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: logging.ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = allocator;
    _ = io;
    _ = timers;
    _ = context;
    return data;
}

//
// A handler that sends a "test-event" and returns "done".
//
fn eventSendingHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: logging.ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = timers;
    _ = data;
    context.sendEvent(io, allocator, log, try json(allocator, "{\"type\":\"test-event\",\"data\":\"test\"}"));
    return .{ .string = "done" };
}

//
// A handler that returns its name. The task named "running" holds its worker until the test cancels `release_source`.
//
fn orderedTaskHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: logging.ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = context;
    const name = data.object.get("name").?;
    if (std.mem.eql(u8, name.string, "running")) {
        try waitForRelease(allocator, io, timers, release_source);
    }
    return name;
}

//
// Sets a boolean flag (used as a callback that must not be called).
//
fn setFlagOnComplete(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, result: ITaskResult) anyerror!void {
    _ = log;
    _ = io;
    _ = allocator;
    _ = result;
    const flag: *bool = @ptrCast(@alignCast(context.?));
    flag.* = true;
}

//
// Sets a boolean flag (used as an event callback that must not be called).
//
fn setFlagOnEvent(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, data: types.ITaskEventData) anyerror!void {
    _ = log;
    _ = io;
    _ = allocator;
    _ = data;
    const flag: *bool = @ptrCast(@alignCast(context.?));
    flag.* = true;
}

//
// Records the completion results passed to a callback (copies what it keeps, with the test thread's allocator, which it is given).
//
const ResultsRecorder = struct {
    // The status of each result.
    statuses: std.ArrayList(TaskStatus),
    // The error message of each result ("" when none).
    errorMessages: std.ArrayList([]const u8),
    // Whether each result had an error object.
    hasError: std.ArrayList(bool),
    // The output of each result as JSON text ("null" when there is none).
    outputs: std.ArrayList([]const u8),

    const empty: ResultsRecorder = .{
        .statuses = .empty,
        .errorMessages = .empty,
        .hasError = .empty,
        .outputs = .empty,
    };

    //
    // The completion callback.
    //
    fn record(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, result: ITaskResult) anyerror!void {
        _ = log;
        _ = io;
        const self: *ResultsRecorder = @ptrCast(@alignCast(context.?));
        try self.statuses.append(allocator, result.status);
        try self.errorMessages.append(allocator, try allocator.dupe(u8, if (result.@"error") |task_error| task_error.message else ""));
        try self.hasError.append(allocator, result.@"error" != null);
        try self.outputs.append(allocator, try std.json.Stringify.valueAlloc(allocator, result.outputs orelse .null, .{}));
    }
};

//
// Counts the tasks that have sent "started" and have not ended, and the most there were at once, from the events and the results the
// test thread reads. A worker sends a task's end before it starts its next task, so what this counts is never more than ran at once.
//
const RunningCounter = struct {
    // How many have started and not ended.
    running: u32,
    // The most that were running at once.
    most: u32,
    // How many have started.
    started: u32,

    const empty: RunningCounter = .{
        .running = 0,
        .most = 0,
        .started = 0,
    };

    //
    // The event callback: a task has started.
    //
    fn taskStarted(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, data: types.ITaskEventData) anyerror!void {
        _ = log;
        _ = io;
        _ = allocator;
        const self: *RunningCounter = @ptrCast(@alignCast(context.?));
        if (!std.mem.eql(u8, ziggy.json.getString(data.event, "type") orelse "", "started")) {
            return;
        }
        self.running += 1;
        self.started += 1;
        self.most = @max(self.most, self.running);
    }

    //
    // The completion callback: a task has ended.
    //
    fn taskEnded(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, result: ITaskResult) anyerror!void {
        _ = log;
        _ = io;
        _ = allocator;
        _ = result;
        const self: *RunningCounter = @ptrCast(@alignCast(context.?));
        self.running -= 1;
    }
};

//
// Shuts a queue down from a completion callback, which runs while the queue's owner waits.
//
fn shutDownQueue(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, result: ITaskResult) anyerror!void {
    const console_log = logging.mute_log.MuteLog.init();
    _ = log;
    _ = result;
    const queue: *TaskQueue = @ptrCast(@alignCast(context.?));
    queue.shutdown(io, allocator, console_log);
}

//
// Cancels the "test" source of a pool from a completion callback, which runs while the queue's owner waits.
//
fn cancelTestSource(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, result: ITaskResult) anyerror!void {
    const console_log = logging.mute_log.MuteLog.init();
    _ = log;
    _ = result;
    const pool: *MockWorkerPool = @ptrCast(@alignCast(context.?));
    pool.cancelTasks(io, allocator, console_log, "test");
}

test "should add a task and return a UUID" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    const taskId = try setup.queue.addTask(io, allocator, console_log, "test-task", try json(allocator, "{\"data\":\"test\"}"), null, null);
    try std.testing.expectEqual(@as(usize, 36), taskId.len);
    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);
}

test "should add multiple tasks with unique IDs" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    const id1 = try setup.queue.addTask(io, allocator, console_log, "test-task", try json(allocator, "{\"data\":\"test1\"}"), null, null);
    const id2 = try setup.queue.addTask(io, allocator, console_log, "test-task", try json(allocator, "{\"data\":\"test2\"}"), null, null);
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);
}

test "addTask hands the priority it was given to the backend" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};

    var recordingBackend: RecordingBackend = std.mem.zeroes(RecordingBackend);
    setQueueBackend(recordingBackend.queueBackend());
    defer setQueueBackend(null);
    const testQueue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "test");

    _ = try testQueue.addTask(io, allocator, console_log, "test-task", try json(allocator, "{\"data\":\"test\"}"), "task-id", .Interactive);

    try std.testing.expectEqual(@as(usize, 1), recordingBackend.capturedCount);
    try std.testing.expectEqualStrings("test-task", recordingBackend.capturedTypes[0]);
    try std.testing.expectEqualStrings("test", recordingBackend.capturedSources[0]);
    try std.testing.expectEqualStrings("task-id", recordingBackend.capturedIds[0]);
    try std.testing.expectEqual(@as(?TaskPriority, .Interactive), recordingBackend.capturedPriorities[0]);

    testQueue.deinit(io, allocator, console_log);
}

test "addTask hands no priority to the backend when the caller named none" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};

    var recordingBackend: RecordingBackend = std.mem.zeroes(RecordingBackend);
    recordingBackend.capturedPriorities[0] = .Background;
    setQueueBackend(recordingBackend.queueBackend());
    defer setQueueBackend(null);
    const testQueue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "test");

    _ = try testQueue.addTask(io, allocator, console_log, "test-task", try json(allocator, "{\"data\":\"test\"}"), "task-id", null);

    try std.testing.expectEqual(@as(usize, 1), recordingBackend.capturedCount);
    try std.testing.expectEqualStrings("task-id", recordingBackend.capturedIds[0]);
    try std.testing.expectEqual(@as(?TaskPriority, null), recordingBackend.capturedPriorities[0]);

    testQueue.deinit(io, allocator, console_log);
}

test "an interactive task is dispatched before background tasks already waiting" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};

    // A pool of one, so the first task holds the only slot and the rest queue behind it.
    const serialBackend = try MockWorkerPool.init(allocator, 1, test_base_context, &test_task_types);
    setQueueBackend(serialBackend.queueBackend());
    const serialQueue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "serial");
    defer {
        serialQueue.deinit(io, allocator, console_log);
        setQueueBackend(null);
        serialBackend.deinit(io, allocator, timers, console_log);
    }
    var results: ResultsRecorder = .empty;
    _ = try serialQueue.onTaskComplete(allocator, .{ .context = &results, .function = ResultsRecorder.record });

    _ = try serialQueue.addTask(io, allocator, console_log, "ordered-task", try json(allocator, "{\"name\":\"running\"}"), null, null);
    // The first task is sent to the worker once the worker reports it is ready, and holds it while the rest are queued.
    while (serialBackend.pool.pending_tasks.items.len > 0) {
        serialBackend.waitForMessage(io, allocator, timers, console_log);
    }
    _ = try serialQueue.addTask(io, allocator, console_log, "ordered-task", try json(allocator, "{\"name\":\"background-1\"}"), null, null);
    _ = try serialQueue.addTask(io, allocator, console_log, "ordered-task", try json(allocator, "{\"name\":\"background-2\"}"), null, null);
    _ = try serialQueue.addTask(io, allocator, console_log, "ordered-task", try json(allocator, "{\"name\":\"interactive\"}"), null, .Interactive);

    const pendingTypes = try serialBackend.getPendingTaskTypes(allocator);
    try std.testing.expectEqual(@as(usize, 3), pendingTypes.len);

    serialBackend.cancelTasks(io, allocator, console_log, release_source);
    try serialQueue.awaitAllTasks(io, allocator, timers, console_log);

    // One worker runs the tasks one after another, so they end in the order they started.
    const expected = [_][]const u8{ "\"running\"", "\"interactive\"", "\"background-1\"", "\"background-2\"" };
    try std.testing.expectEqual(expected.len, results.outputs.items.len);
    for (expected, results.outputs.items) |expected_name, actual_name| {
        try std.testing.expectEqualStrings(expected_name, actual_name);
    }
}

test "awaitTask resolves when the specific task completes" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    const taskId = try setup.queue.addTask(io, allocator, console_log, "test-task", .null, null, null);
    const result = (try setup.queue.awaitTask(io, allocator, timers, console_log, taskId)).?;
    try std.testing.expectEqualStrings(taskId, result.taskId);
    try std.testing.expectEqual(TaskStatus.Succeeded, result.status);
    try std.testing.expectEqualStrings("done", result.outputs.?.string);
}

test "awaitTask resolves immediately when the task ID is not tracked" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    try std.testing.expect((try setup.queue.awaitTask(io, allocator, timers, console_log, "unknown-task-id")) == null);
}

test "awaitTask resolves for each task awaited in turn, the second after the first has resolved" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    const slowId = try setup.queue.addTask(io, allocator, console_log, "slow-task", .null, null, null);
    const quickId = try setup.queue.addTask(io, allocator, console_log, "test-task", .null, null, null);
    const quick = (try setup.queue.awaitTask(io, allocator, timers, console_log, quickId)).?;
    try std.testing.expectEqual(TaskStatus.Succeeded, quick.status);
    setup.backend.cancelTasks(io, allocator, console_log, release_source);
    const slow = (try setup.queue.awaitTask(io, allocator, timers, console_log, slowId)).?;
    try std.testing.expectEqualStrings("done", slow.outputs.?.string);
}

test "awaitTask resolves immediately when shutdown is called while waiting" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);
    defer setup.backend.cancelTasks(io, allocator, console_log, release_source);

    const taskId = try setup.queue.addTask(io, allocator, console_log, "slow-task", .null, null, null);
    // The queue is shut down while awaitTask waits, by the callback of another task's completion, before the slow task completes.
    _ = try setup.queue.onTaskComplete(allocator, .{ .context = setup.queue, .function = shutDownQueue });
    _ = try setup.queue.addTask(io, allocator, console_log, "test-task", .null, null, null);
    const result = try setup.queue.awaitTask(io, allocator, timers, console_log, taskId);

    try std.testing.expect(result == null);
}

test "should wait for all tasks to complete" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);
    var results: ResultsRecorder = .empty;
    _ = try setup.queue.onTaskComplete(allocator, .{ .context = &results, .function = ResultsRecorder.record });

    _ = try setup.queue.addTask(io, allocator, console_log, "counting-task", try json(allocator, "{\"id\":1}"), null, null);
    _ = try setup.queue.addTask(io, allocator, console_log, "counting-task", try json(allocator, "{\"id\":2}"), null, null);
    _ = try setup.queue.addTask(io, allocator, console_log, "counting-task", try json(allocator, "{\"id\":3}"), null, null);

    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);

    try std.testing.expectEqual(@as(usize, 3), results.statuses.items.len);
}

test "should resolve immediately if no tasks" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);
}

test "should handle mixed success and failure" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    _ = try setup.queue.addTask(io, allocator, console_log, "success-task", .null, null, null);
    _ = try setup.queue.addTask(io, allocator, console_log, "fail-task", .null, null, null);
    _ = try setup.queue.addTask(io, allocator, console_log, "success-task", .null, null, null);

    // awaitAllTasks returns after all tasks complete, whether succeeded or failed.
    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);
    try std.testing.expectEqual(@as(i64, 0), setup.queue.numTasksInFlight);
}

test "should handle empty queue" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);
}

test "awaitAllTasks resolves immediately when shutdown is called while waiting" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);
    defer setup.backend.cancelTasks(io, allocator, console_log, release_source);

    _ = try setup.queue.addTask(io, allocator, console_log, "slow-task", .null, null, null);
    // Shut down before the slow task completes, from the callback of another task's completion: awaitAllTasks should return then.
    _ = try setup.queue.onTaskComplete(allocator, .{ .context = setup.queue, .function = shutDownQueue });
    _ = try setup.queue.addTask(io, allocator, console_log, "test-task", .null, null, null);
    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);
}

test "onTasksCancelled fires resolveAllWaiters, unblocking awaitAllTasks and awaitTask callers" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);
    defer setup.backend.cancelTasks(io, allocator, console_log, release_source);

    const taskId = try setup.queue.addTask(io, allocator, console_log, "slow-task", .null, null, null);
    // cancelTasks fires onTasksCancelled, which calls resolveAllWaiters, while the queue waits. Each quick task's completion cancels
    // the source while the slow task is still running: the first while awaitAllTasks waits, the second while awaitTask waits.
    _ = try setup.queue.onTaskComplete(allocator, .{ .context = setup.backend, .function = cancelTestSource });
    _ = try setup.queue.addTask(io, allocator, console_log, "test-task", .null, null, null);
    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);
    _ = try setup.queue.addTask(io, allocator, console_log, "test-task", .null, null, null);
    try std.testing.expect((try setup.queue.awaitTask(io, allocator, timers, console_log, taskId)) == null);
}

test "should wait for all tasks including slow ones" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);
    var results: ResultsRecorder = .empty;
    _ = try setup.queue.onTaskComplete(allocator, .{ .context = &results, .function = ResultsRecorder.record });

    _ = try setup.queue.addTask(io, allocator, console_log, "slow-counting-task", .null, null, null);
    _ = try setup.queue.addTask(io, allocator, console_log, "slow-counting-task", .null, null, null);
    _ = try setup.queue.addTask(io, allocator, console_log, "slow-counting-task", .null, null, null);

    const startTime = nowMs();
    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);
    const duration = nowMs() - startTime;

    try std.testing.expectEqual(@as(usize, 3), results.statuses.items.len);

    // Should take at least 100ms (with 2 workers, tasks run in parallel).
    try std.testing.expect(duration >= 100);
}

test "should execute tasks in parallel up to maxWorkers" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);
    var counter: RunningCounter = .empty;
    _ = try setup.queue.onAnyTaskEvent(allocator, .{ .context = &counter, .function = RunningCounter.taskStarted });
    _ = try setup.queue.onTaskComplete(allocator, .{ .context = &counter, .function = RunningCounter.taskEnded });

    // Two tasks that hold their workers: both start, so two run at once.
    var task_number: i64 = 1;
    while (task_number <= 2) : (task_number += 1) {
        const data = try json(allocator, try utils.json.stringify(allocator, .{
            .id = task_number,
            .hold = true,
        }));
        _ = try setup.queue.addTask(io, allocator, console_log, "recording-task", data, null, null);
    }
    while (counter.started < 2) {
        setup.backend.waitForMessage(io, allocator, timers, console_log);
    }
    try std.testing.expectEqual(@as(u32, 2), counter.running);
    setup.backend.cancelTasks(io, allocator, console_log, release_source);

    // Three more, which run in the workers the first two leave.
    while (task_number <= 5) : (task_number += 1) {
        const data = try json(allocator, try utils.json.stringify(allocator, .{
            .id = task_number,
        }));
        _ = try setup.queue.addTask(io, allocator, console_log, "recording-task", data, null, null);
    }

    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);

    // All tasks should complete.
    try std.testing.expectEqual(@as(u32, 5), counter.started);
    try std.testing.expectEqual(@as(u32, 0), counter.running);
}

test "should respect maxWorkers limit" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};

    const limitedBackend = try MockWorkerPool.init(allocator, 2, test_base_context, &test_task_types);
    setQueueBackend(limitedBackend.queueBackend());
    const queueWithLimit = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "test-limited");
    defer {
        queueWithLimit.deinit(io, allocator, console_log);
        setQueueBackend(null);
        limitedBackend.deinit(io, allocator, timers, console_log);
    }
    var counter: RunningCounter = .empty;
    _ = try queueWithLimit.onAnyTaskEvent(allocator, .{ .context = &counter, .function = RunningCounter.taskStarted });
    _ = try queueWithLimit.onTaskComplete(allocator, .{ .context = &counter, .function = RunningCounter.taskEnded });

    // Add 10 tasks with maxWorkers=2.
    var task_number: i64 = 1;
    while (task_number <= 10) : (task_number += 1) {
        const data = try json(allocator, try utils.json.stringify(allocator, .{
            .id = task_number,
        }));
        _ = try queueWithLimit.addTask(io, allocator, console_log, "recording-task", data, null, null);
    }

    try queueWithLimit.awaitAllTasks(io, allocator, timers, console_log);

    // Should never exceed maxWorkers (2).
    try std.testing.expect(counter.most <= 2);
    try std.testing.expectEqual(@as(u32, 10), counter.started);
}

test "should process tasks in FIFO order" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};

    const singleWorkerBackend = try MockWorkerPool.init(allocator, 1, test_base_context, &test_task_types);
    setQueueBackend(singleWorkerBackend.queueBackend());
    const singleQueue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "test-fifo");
    defer {
        singleQueue.deinit(io, allocator, console_log);
        setQueueBackend(null);
        singleWorkerBackend.deinit(io, allocator, timers, console_log);
    }
    var results: ResultsRecorder = .empty;
    _ = try singleQueue.onTaskComplete(allocator, .{ .context = &results, .function = ResultsRecorder.record });

    // Add tasks in order.
    var task_number: i64 = 1;
    while (task_number <= 5) : (task_number += 1) {
        const data = try json(allocator, try utils.json.stringify(allocator, .{
            .id = task_number,
        }));
        _ = try singleQueue.addTask(io, allocator, console_log, "recording-task", data, null, null);
    }

    try singleQueue.awaitAllTasks(io, allocator, timers, console_log);

    // One worker runs the tasks one after another, so they end in the order they were processed: FIFO.
    const expected = [_][]const u8{ "1", "2", "3", "4", "5" };
    try std.testing.expectEqual(expected.len, results.outputs.items.len);
    for (expected, results.outputs.items) |expected_id, actual_id| {
        try std.testing.expectEqualStrings(expected_id, actual_id);
    }
}

//
// Runs a task of the type "echo-task" with the data and returns its output as JSON text.
//
fn echoedJson(io: std.Io, allocator: std.mem.Allocator, timers: Timers, data: std.json.Value) ![]const u8 {
    const console_log = logging.mute_log.MuteLog.init();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);
    const taskId = try setup.queue.addTask(io, allocator, console_log, "echo-task", data, null, null);
    const result = (try setup.queue.awaitTask(io, allocator, timers, console_log, taskId)).?;
    return try std.json.Stringify.valueAlloc(allocator, result.outputs orelse .null, .{});
}

test "should pass task data to handler" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var timer_list = TimerList.init();

    const taskData = "{\"file\":\"test.jpg\",\"options\":{\"quality\":90},\"metadata\":{\"author\":\"test\"}}";
    try std.testing.expectEqualStrings(taskData, try echoedJson(std.testing.io, allocator, timer_list.interface(), try json(allocator, taskData)));
}

test "should handle complex data structures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var timer_list = TimerList.init();

    const complexData = "{\"nested\":{\"array\":[1,2,3],\"object\":{\"key\":\"value\"}},\"date\":\"2024-01-01T00:00:00.000Z\"}";
    const received = try json(allocator, try echoedJson(std.testing.io, allocator, timer_list.interface(), try json(allocator, complexData)));
    const nested = received.object.get("nested").?.object;
    try std.testing.expectEqual(@as(usize, 3), nested.get("array").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 2), nested.get("array").?.array.items[1].integer);
    try std.testing.expectEqualStrings("value", nested.get("object").?.object.get("key").?.string);
}

test "should handle null data" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var timer_list = TimerList.init();

    try std.testing.expectEqualStrings("null", try echoedJson(std.testing.io, allocator, timer_list.interface(), .null));
}

test "should handle empty object data" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var timer_list = TimerList.init();

    try std.testing.expectEqualStrings("{}", try echoedJson(std.testing.io, allocator, timer_list.interface(), try json(allocator, "{}")));
}

test "should handle array data" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var timer_list = TimerList.init();

    const arrayData = "[1,2,3,\"test\",{\"key\":\"value\"}]";
    try std.testing.expectEqualStrings(arrayData, try echoedJson(std.testing.io, allocator, timer_list.interface(), try json(allocator, arrayData)));
}

test "should terminate all workers" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    // Should not throw.
    setup.queue.shutdown(io, allocator, console_log);
}

test "should allow shutdown multiple times" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    // Should not throw.
    setup.queue.shutdown(io, allocator, console_log);
    setup.queue.shutdown(io, allocator, console_log);
}

test "should prevent callbacks from being called after shutdown" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    var callbackCalled = false;
    _ = try setup.queue.onTaskComplete(allocator, .{ .context = &callbackCalled, .function = setFlagOnComplete });

    // Shutdown the queue.
    setup.queue.shutdown(io, allocator, console_log);

    _ = try setup.queue.addTask(io, allocator, console_log, "test-task", .null, null, null);

    // Read every message the task sends, so any callback that is going to fire has fired.
    setup.waitUntilIdle(io, allocator, timers);
    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);

    // Callback should not be called after shutdown.
    try std.testing.expect(!callbackCalled);
}

test "should prevent task events from being received after shutdown" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    var callbackCalled = false;
    _ = try setup.queue.onTaskEvent(allocator, "test-event", .{ .context = &callbackCalled, .function = setFlagOnEvent });

    // Shutdown the queue.
    setup.queue.shutdown(io, allocator, console_log);

    _ = try setup.queue.addTask(io, allocator, console_log, "event-task", .null, null, null);

    // Read every message the task sends, so any callback that is going to fire has fired.
    setup.waitUntilIdle(io, allocator, timers);
    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);

    // Callback should not be called after shutdown.
    try std.testing.expect(!callbackCalled);
}

//
// A backend that records the task IDs it is given and which of its subscriptions were removed.
//
const RecordingBackend = struct {
    // The task IDs passed to addTask (static storage, no allocation needed).
    capturedIds: [4][]const u8,

    // The task types passed to addTask.
    capturedTypes: [4][]const u8,

    // The sources passed to addTask.
    capturedSources: [4][]const u8,

    // The priorities passed to addTask.
    capturedPriorities: [4]?TaskPriority,

    // Number of valid entries in capturedIds, capturedTypes, capturedSources and capturedPriorities.
    capturedCount: usize,

    // Set when the onTaskAdded subscription is removed.
    onTaskAddedUnsubscribeCalled: bool,

    // Set when the onTaskComplete subscription is removed.
    onTaskCompleteUnsubscribeCalled: bool,

    // Set when the onAnyTaskEvent subscription is removed.
    onAnyTaskEventUnsubscribeCalled: bool,

    //
    // Gets the IQueueBackend interface for this backend.
    //
    fn queueBackend(self: *RecordingBackend) IQueueBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The IQueueBackend functions of this backend.
    //
    const vtable: IQueueBackend.VTable = .{
        .addTask = addTask,
        .onTaskAdded = onTaskAdded,
        .onTaskComplete = onTaskComplete,
        .onTaskEvent = onTaskEvent,
        .onAnyTaskEvent = onAnyTaskEvent,
        .cancelTasks = cancelTasks,
        .onTasksCancelled = onTasksCancelled,
        .shutdown = shutdown,
        .waitForMessage = waitForMessage,
    };

    //
    // Records the task ID.
    //
    fn addTask(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, log: ziggy.log.ILog, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) anyerror![]const u8 {
        _ = log;
        _ = io;
        _ = data;
        const self: *RecordingBackend = @ptrCast(@alignCast(ptr));
        self.capturedIds[self.capturedCount] = taskId orelse "";
        self.capturedTypes[self.capturedCount] = @"type";
        self.capturedSources[self.capturedCount] = source;
        self.capturedPriorities[self.capturedCount] = priority;
        self.capturedCount += 1;
        return try allocator.dupe(u8, taskId orelse "");
    }

    //
    // Records which subscription was removed (the key names which one).
    //
    fn unsubscribe(context: ?*anyopaque, allocator: std.mem.Allocator, key: usize) void {
        _ = allocator;
        const self: *RecordingBackend = @ptrCast(@alignCast(context.?));
        switch (key) {
            1 => self.onTaskAddedUnsubscribeCalled = true,
            2 => self.onTaskCompleteUnsubscribeCalled = true,
            3 => self.onAnyTaskEventUnsubscribeCalled = true,
            else => {},
        }
    }

    //
    // Returns the unsubscribe function for onTaskAdded.
    //
    fn onTaskAdded(ptr: *anyopaque, allocator: std.mem.Allocator, source: []const u8, callback: types.TaskAddedCallback) anyerror!types.UnsubscribeFn {
        _ = allocator;
        _ = source;
        _ = callback;
        return .{ .context = ptr, .key = 1, .function = unsubscribe };
    }

    //
    // Returns the unsubscribe function for onTaskComplete.
    //
    fn onTaskComplete(ptr: *anyopaque, allocator: std.mem.Allocator, callback: types.WorkerTaskCompletionCallback) anyerror!types.UnsubscribeFn {
        _ = allocator;
        _ = callback;
        return .{ .context = ptr, .key = 2, .function = unsubscribe };
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTaskEvent(ptr: *anyopaque, allocator: std.mem.Allocator, eventType: []const u8, callback: types.TaskEventCallback) anyerror!types.UnsubscribeFn {
        _ = allocator;
        _ = eventType;
        _ = callback;
        return .{ .context = ptr, .key = 0, .function = unsubscribe };
    }

    //
    // Returns the unsubscribe function for onAnyTaskEvent.
    //
    fn onAnyTaskEvent(ptr: *anyopaque, allocator: std.mem.Allocator, callback: types.TaskEventCallback) anyerror!types.UnsubscribeFn {
        _ = allocator;
        _ = callback;
        return .{ .context = ptr, .key = 3, .function = unsubscribe };
    }

    //
    // Does nothing.
    //
    fn cancelTasks(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, log: ziggy.log.ILog, source: []const u8) void {
        _ = log;
        _ = ptr;
        _ = io;
        _ = allocator;
        _ = source;
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTasksCancelled(ptr: *anyopaque, allocator: std.mem.Allocator, source: []const u8, callback: types.TasksCancelledCallback) anyerror!types.UnsubscribeFn {
        _ = allocator;
        _ = source;
        _ = callback;
        return .{ .context = ptr, .key = 0, .function = unsubscribe };
    }

    //
    // Does nothing.
    //
    fn shutdown(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        _ = ptr;
        _ = io;
        _ = allocator;
    }

    //
    // Has no messages, because nothing it is given ever completes.
    //
    fn waitForMessage(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ziggy.log.ILog) void {
        _ = log;
        _ = ptr;
        _ = io;
        _ = allocator;
        _ = timers;
        @panic("the recording backend has no messages to wait for");
    }
};

test "should unsubscribe from all backend events on shutdown" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};

    // Create a mock backend that tracks unsubscribe calls.
    var mockTestBackend: RecordingBackend = std.mem.zeroes(RecordingBackend);
    setQueueBackend(mockTestBackend.queueBackend());
    defer setQueueBackend(null);
    const testQueue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "test-unsub");

    // Shutdown should call all unsubscribe functions.
    testQueue.shutdown(io, allocator, console_log);

    try std.testing.expect(mockTestBackend.onTaskCompleteUnsubscribeCalled);
    try std.testing.expect(mockTestBackend.onAnyTaskEventUnsubscribeCalled);
    try std.testing.expect(mockTestBackend.onTaskAddedUnsubscribeCalled);
    testQueue.deinit(io, allocator, console_log);
}

test "tasks from source A do not trigger completion callbacks of source B" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    const queueB = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "source-b");
    defer queueB.deinit(io, allocator, console_log);
    var callbackBFired = false;
    _ = try queueB.onTaskComplete(allocator, .{ .context = &callbackBFired, .function = setFlagOnComplete });

    // Add a task to queue A (source "test").
    _ = try setup.queue.addTask(io, allocator, console_log, "test-task", .null, null, null);
    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);

    // Nothing is queued for queue B.
    try queueB.awaitAllTasks(io, allocator, timers, console_log);
    try std.testing.expect(!callbackBFired);
}

test "addTask with an explicit taskId passes that ID through to the backend" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};

    const explicitId = "my-explicit-task-id";
    var recordingBackend: RecordingBackend = std.mem.zeroes(RecordingBackend);
    setQueueBackend(recordingBackend.queueBackend());
    defer setQueueBackend(null);
    const testQueue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "test-explicit");

    const returnedId = try testQueue.addTask(io, allocator, console_log, "test-task", .null, explicitId, null);

    try std.testing.expectEqualStrings(explicitId, returnedId);
    try std.testing.expectEqual(@as(usize, 1), recordingBackend.capturedCount);
    try std.testing.expectEqualStrings(explicitId, recordingBackend.capturedIds[0]);

    testQueue.deinit(io, allocator, console_log);
}

test "should use custom UUID generator" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    // The TestUuidGenerator keeps its counter in TEST_TMP_DIR.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var environ_map = std.process.Environ.Map.init(allocator);
    try environ_map.put("TEST_TMP_DIR", try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp_dir.sub_path }));
    utils.process_env.setEnvironMap(&environ_map);
    defer utils.process_env.setEnvironMap(null);

    var customUuidGenerator = try utils.file_test_uuid_generator.TestUuidGenerator.init(allocator);
    const customQueue = try TaskQueue.init(allocator, customUuidGenerator.uuidGenerator(), "test-custom");
    defer customQueue.deinit(io, allocator, console_log);

    const taskId1 = try customQueue.addTask(io, allocator, console_log, "test-task", .null, null, null);
    const taskId2 = try customQueue.addTask(io, allocator, console_log, "test-task", .null, null, null);

    // TestUuidGenerator creates deterministic UUIDs.
    try std.testing.expect(taskId1.len > 0);
    try std.testing.expect(taskId2.len > 0);
    try std.testing.expect(!std.mem.eql(u8, taskId1, taskId2));

    try customQueue.awaitAllTasks(io, allocator, timers, console_log);
}

test "should use default UUID generator when not provided" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    var customUuidGenerator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    const defaultQueue = try TaskQueue.init(allocator, customUuidGenerator.uuidGenerator(), "test-default");
    defer defaultQueue.deinit(io, allocator, console_log);

    const taskId1 = try defaultQueue.addTask(io, allocator, console_log, "test-task", .null, null, null);
    const taskId2 = try defaultQueue.addTask(io, allocator, console_log, "test-task", .null, null, null);

    try std.testing.expect(taskId1.len > 0);
    try std.testing.expect(taskId2.len > 0);
    try std.testing.expect(!std.mem.eql(u8, taskId1, taskId2));

    try defaultQueue.awaitAllTasks(io, allocator, timers, console_log);
}

//
// A handler that fails with a plain Zig error that has no recorded message
// (the closest Zig equivalent of throwing a value that is not an Error).
//
fn plainZigErrorHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: logging.ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = allocator;
    _ = io;
    _ = timers;
    _ = data;
    _ = context;
    return error.StringError;
}

//
// A handler that throws "Custom error message".
//
fn customErrorHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: logging.ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = allocator;
    _ = io;
    _ = timers;
    _ = data;
    _ = context;
    return errors.throwError("Custom error message", .{});
}

test "should handle handler throwing non-Error objects" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    var recorder: ResultsRecorder = .empty;
    _ = try setup.queue.onTaskComplete(allocator, .{ .context = &recorder, .function = ResultsRecorder.record });

    _ = try setup.queue.addTask(io, allocator, console_log, "throw-string", .null, null, null);
    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);

    try std.testing.expectEqual(@as(usize, 1), recorder.statuses.items.len);
    try std.testing.expectEqual(TaskStatus.Failed, recorder.statuses.items[0]);
    try std.testing.expect(recorder.hasError.items[0]);
    try std.testing.expectEqualStrings("StringError", recorder.errorMessages.items[0]);
}

test "should preserve error messages" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    var recorder: ResultsRecorder = .empty;
    _ = try setup.queue.onTaskComplete(allocator, .{ .context = &recorder, .function = ResultsRecorder.record });

    _ = try setup.queue.addTask(io, allocator, console_log, "custom-error", .null, null, null);
    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);

    try std.testing.expectEqual(@as(usize, 1), recorder.statuses.items.len);
    try std.testing.expectEqual(TaskStatus.Failed, recorder.statuses.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, recorder.errorMessages.items[0], "Custom error message") != null);
}

//
// Records the progress strings of "replicate-progress" events (like replicateDatabase's onProgress), copied with the test thread's
// allocator, which it is given.
//
const ProgressRecorder = struct {
    // The progress strings received.
    progress: std.ArrayList([]const u8),

    //
    // The event callback.
    //
    fn record(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, data: types.ITaskEventData) anyerror!void {
        _ = log;
        _ = io;
        const self: *ProgressRecorder = @ptrCast(@alignCast(context.?));
        try self.progress.append(allocator, try allocator.dupe(u8, data.event.object.get("progress").?.string));
    }
};

//
// A handler that sends two progress events and an event of another type, then returns.
//
fn progressHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: logging.ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = timers;
    _ = data;
    context.sendEvent(io, allocator, log, try json(allocator, "{\"type\":\"replicate-progress\",\"databasePath\":\"/db\",\"progress\":\"one\"}"));
    context.sendEvent(io, allocator, log, try json(allocator, "{\"type\":\"other\",\"progress\":\"ignored\"}"));
    context.sendEvent(io, allocator, log, try json(allocator, "{\"type\":\"replicate-progress\",\"databasePath\":\"/db\",\"progress\":\"two\"}"));
    return json(allocator, "{\"filesCopied\":2}");
}

test "onTaskEvent delivers only events of the registered type, in order, before awaitTask returns" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    var recorder: ProgressRecorder = .{ .progress = .empty };
    const unsubscribe = try setup.queue.onTaskEvent(allocator, "replicate-progress", .{ .context = &recorder, .function = ProgressRecorder.record });

    const taskId = try setup.queue.addTask(io, allocator, console_log, "progress-task", .null, null, null);
    const result = (try setup.queue.awaitTask(io, allocator, timers, console_log, taskId)).?;

    try std.testing.expectEqual(TaskStatus.Succeeded, result.status);
    try std.testing.expectEqual(@as(i64, 2), result.outputs.?.object.get("filesCopied").?.integer);
    try std.testing.expectEqual(@as(usize, 2), recorder.progress.items.len);
    try std.testing.expectEqualStrings("one", recorder.progress.items[0]);
    try std.testing.expectEqualStrings("two", recorder.progress.items[1]);

    // After unsubscribing no more events are delivered.
    unsubscribe.call(allocator);
    const secondTaskId = try setup.queue.addTask(io, allocator, console_log, "progress-task", .null, null, null);
    _ = try setup.queue.awaitTask(io, allocator, timers, console_log, secondTaskId);
    try std.testing.expectEqual(@as(usize, 2), recorder.progress.items.len);
}

test "onTaskComplete unsubscribe removes the callback" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    var callbackCalled = false;
    const unsubscribe = try setup.queue.onTaskComplete(allocator, .{ .context = &callbackCalled, .function = setFlagOnComplete });
    unsubscribe.call(allocator);

    _ = try setup.queue.addTask(io, allocator, console_log, "test-task", .null, null, null);
    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);
    try std.testing.expect(!callbackCalled);
}

test "TaskQueue.init throws when no backend is registered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    setQueueBackend(null);
    try std.testing.expectError(error.Thrown, TaskQueue.init(arena.allocator(), uuid_generator.uuidGenerator(), "x"));
}

//
// Records the type of every event it receives (the callback of onAnyTaskEvent), copied with the test thread's allocator, which it is
// given.
//
const EventTypeRecorder = struct {
    // The type of each event received, in order.
    eventTypes: std.ArrayList([]const u8),

    //
    // The event callback.
    //
    fn record(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, data: types.ITaskEventData) anyerror!void {
        _ = log;
        _ = io;
        const self: *EventTypeRecorder = @ptrCast(@alignCast(context.?));
        try self.eventTypes.append(allocator, try allocator.dupe(u8, data.event.object.get("type").?.string));
    }
};

//
// onAnyTaskEvent is what addPaths counts an import's
// progress with, so what it does is pinned here.
//
test "onAnyTaskEvent delivers every event of a tracked task, whatever its type, in order" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    var recorder: EventTypeRecorder = .{
        .eventTypes = .empty,
    };
    const unsubscribe = try setup.queue.onAnyTaskEvent(allocator, .{
        .context = &recorder,
        .function = EventTypeRecorder.record,
    });

    const taskId = try setup.queue.addTask(io, allocator, console_log, "progress-task", .null, null, null);
    _ = try setup.queue.awaitTask(io, allocator, timers, console_log, taskId);

    try std.testing.expectEqual(@as(usize, 3), recorder.eventTypes.items.len);
    try std.testing.expectEqualStrings("replicate-progress", recorder.eventTypes.items[0]);
    try std.testing.expectEqualStrings("other", recorder.eventTypes.items[1]);
    try std.testing.expectEqualStrings("replicate-progress", recorder.eventTypes.items[2]);

    // After unsubscribing no more events are delivered.
    unsubscribe.call(allocator);
    const secondTaskId = try setup.queue.addTask(io, allocator, console_log, "progress-task", .null, null, null);
    _ = try setup.queue.awaitTask(io, allocator, timers, console_log, secondTaskId);
    try std.testing.expectEqual(@as(usize, 3), recorder.eventTypes.items.len);
}

test "onAnyTaskEvent callbacks receive nothing after shutdown" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    var recorder: EventTypeRecorder = .{
        .eventTypes = .empty,
    };
    _ = try setup.queue.onAnyTaskEvent(allocator, .{
        .context = &recorder,
        .function = EventTypeRecorder.record,
    });

    setup.queue.shutdown(io, allocator, console_log);

    _ = try setup.queue.addTask(io, allocator, console_log, "progress-task", .null, null, null);
    // Read every message the task sends, so any callback that is going to fire has fired.
    setup.waitUntilIdle(io, allocator, timers);
    try setup.queue.awaitAllTasks(io, allocator, timers, console_log);

    try std.testing.expectEqual(@as(usize, 0), recorder.eventTypes.items.len);
}

//
// A completion callback that fails.
//
fn failOnComplete(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, result: ITaskResult) anyerror!void {
    _ = log;
    _ = context;
    _ = io;
    _ = allocator;
    _ = result;
    return error.CompletionCallbackFailed;
}

//
// An event callback that fails.
//
fn failOnEvent(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, data: types.ITaskEventData) anyerror!void {
    _ = log;
    _ = context;
    _ = io;
    _ = allocator;
    _ = data;
    return error.EventCallbackFailed;
}

test "callbacks that fail are logged and the other callbacks still run" {
    const memory = try logging.memory_log.MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    const console_log = memory.log;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    _ = try setup.queue.onTaskComplete(allocator, .{ .context = null, .function = failOnComplete });
    _ = try setup.queue.onTaskEvent(allocator, "replicate-progress", .{ .context = null, .function = failOnEvent });
    _ = try setup.queue.onAnyTaskEvent(allocator, .{ .context = null, .function = failOnEvent });
    var completed = false;
    _ = try setup.queue.onTaskComplete(allocator, .{ .context = &completed, .function = setFlagOnComplete });
    var progress: ProgressRecorder = .{ .progress = .empty };
    _ = try setup.queue.onTaskEvent(allocator, "replicate-progress", .{ .context = &progress, .function = ProgressRecorder.record });

    const taskId = try setup.queue.addTask(io, allocator, console_log, "progress-task", .null, null, null);
    const result = (try setup.queue.awaitTask(io, allocator, timers, console_log, taskId)).?;
    try std.testing.expectEqual(TaskStatus.Succeeded, result.status);
    try std.testing.expect(completed);
    try std.testing.expectEqual(@as(usize, 2), progress.progress.items.len);

    const logged = memory.stderr();
    try std.testing.expect(std.mem.indexOf(u8, logged, "Error in task completion callback") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "Error in task event callback") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "Error in any task event callback") != null);
}

test "unsubscribing leaves the other callbacks, and unsubscribing twice does nothing" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);

    var firstCompleted = false;
    var secondCompleted = false;
    _ = try setup.queue.onTaskComplete(allocator, .{ .context = &firstCompleted, .function = setFlagOnComplete });
    const unsubscribeCompletion = try setup.queue.onTaskComplete(allocator, .{ .context = &secondCompleted, .function = setFlagOnComplete });
    var firstNotified = false;
    var secondNotified = false;
    _ = try setup.queue.onTaskEvent(allocator, "replicate-progress", .{ .context = &firstNotified, .function = setFlagOnEvent });
    const unsubscribeEvent = try setup.queue.onTaskEvent(allocator, "replicate-progress", .{ .context = &secondNotified, .function = setFlagOnEvent });
    var firstAnyNotified = false;
    var secondAnyNotified = false;
    _ = try setup.queue.onAnyTaskEvent(allocator, .{ .context = &firstAnyNotified, .function = setFlagOnEvent });
    const unsubscribeAnyEvent = try setup.queue.onAnyTaskEvent(allocator, .{ .context = &secondAnyNotified, .function = setFlagOnEvent });

    for (0..2) |_| {
        unsubscribeCompletion.call(allocator);
        unsubscribeEvent.call(allocator);
        unsubscribeAnyEvent.call(allocator);
    }

    const taskId = try setup.queue.addTask(io, allocator, console_log, "progress-task", .null, null, null);
    _ = try setup.queue.awaitTask(io, allocator, timers, console_log, taskId);
    try std.testing.expect(firstCompleted and !secondCompleted);
    try std.testing.expect(firstNotified and !secondNotified);
    try std.testing.expect(firstAnyNotified and !secondAnyNotified);
}

test "callers awaiting different tasks each resolve when their own task completes" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    const setup = try Setup.init(allocator, 2);
    defer setup.deinit(io, allocator, timers);
    defer setup.backend.cancelTasks(io, allocator, console_log, second_release_source);

    const firstTaskId = try setup.queue.addTask(io, allocator, console_log, "slow-task", .null, null, null);
    const secondTaskId = try setup.queue.addTask(io, allocator, console_log, "second-slow-task", .null, null, null);
    // The second task is held until the first has been awaited. A task that ends while nothing waits for it is no longer tracked, and
    // awaitTask returns null for it. A release reaches only the workers that have been sent their task, so both are sent first.
    setup.waitUntilDispatched(io, allocator, timers);
    setup.backend.cancelTasks(io, allocator, console_log, release_source);
    const first = (try setup.queue.awaitTask(io, allocator, timers, console_log, firstTaskId)).?;
    setup.backend.cancelTasks(io, allocator, console_log, second_release_source);
    const second = (try setup.queue.awaitTask(io, allocator, timers, console_log, secondTaskId)).?;
    try std.testing.expectEqualStrings(firstTaskId, first.taskId);
    try std.testing.expectEqualStrings(secondTaskId, second.taskId);
    try std.testing.expectEqual(TaskStatus.Succeeded, first.status);
    try std.testing.expectEqual(TaskStatus.Succeeded, second.status);
}
