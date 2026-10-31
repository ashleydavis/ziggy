//
// Tests for the parts of the queue that only show themselves when more than one thing is happening at
// once: a worker taking the next task while another is still busy, a task failing, a task being
// cancelled, and every path that shuts the queue down.
//
// The workers share nothing with the test's thread. What a task did comes back to the test as its result and its events, and a task
// that holds its worker is let go by a cancel of the source `release_source`, which reaches every worker as a message.
//

const std = @import("std");
const task_queue_zig = @import("ziggy").task_queue;
const utils = ziggy.utils;
const MuteLog = ziggy.log.mute_log.MuteLog;
const ILog = ziggy.log.ILog;
const TaskQueue = task_queue_zig.task_queue.TaskQueue;
const types = task_queue_zig.types;
const ITaskResult = types.ITaskResult;
const ITaskContext = types.ITaskContext;
const ITaskEventData = types.ITaskEventData;
const TaskStatus = types.TaskStatus;
const ziggy = @import("ziggy");
const Timers = ziggy.timers.Timers;
const TimerList = ziggy.timers.TimerList;
const setQueueBackend = task_queue_zig.queue_backend.setQueueBackend;
const getQueueBackend = task_queue_zig.queue_backend.getQueueBackend;
const IQueueBackend = task_queue_zig.queue_backend.IQueueBackend;
const mock_worker_pool = task_queue_zig.mock_worker_pool;
const MockWorkerPool = mock_worker_pool.MockWorkerPool;
const errors = utils.errors;

//
// The source whose cancel lets every held task go.
//
const release_source = "concurrency-release";

//
// The task types the pools of these tests run, each with its handler. "concurrency-no-such-handler" is not one of them.
//
const test_task_types = [_]ziggy.task_runner.TaskHandlerEntry{
    .{ .name = "concurrency-task", .handler = ziggy.task_runner.fromQueueHandler(recordingTaskHandler) },
    .{ .name = "concurrency-failing-task", .handler = ziggy.task_runner.fromQueueHandler(failingHandler) },
    .{ .name = "concurrency-cancellation-task", .handler = ziggy.task_runner.fromQueueHandler(cancellationCheckingHandler) },
    .{ .name = "concurrency-event-task", .handler = ziggy.task_runner.fromQueueHandler(eventSendingTaskHandler) },
};

//
// The context every task of a test runs with.
//
const base_context: mock_worker_pool.IBaseContext = .{
    .sessionId = "test-session",
};

//
// Parses JSON text into a task data value.
//
fn json(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Where a held task is: let go, or out of time.
//
const Hold = struct {
    // Set by the cancel of `release_source`.
    released: bool,
    // Set when no cancel came in time.
    timed_out: bool,
};

//
// The callback of the cancel of `release_source`: lets the held task go.
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
// Holds the task's worker, reading the worker's messages, until the test cancels `release_source`.
//
fn waitForRelease(allocator: std.mem.Allocator, io: std.Io, timers: Timers) !void {
    const console_log = MuteLog.init();
    const backend = try getQueueBackend();
    var hold: Hold = .{
        .released = false,
        .timed_out = false,
    };
    const unsubscribe = try backend.onTasksCancelled(allocator, release_source, .{
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
// A handler that sends an event naming the task when it starts, holds its worker when its data requests it, and returns the name.
//
fn recordingTaskHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    const name = data.object.get("name").?.string;
    var event: std.json.ObjectMap = .empty;
    try event.put(allocator, "type", .{ .string = "started" });
    try event.put(allocator, "name", .{ .string = name });
    context.sendEvent(io, allocator, log, .{ .object = event });
    if (data.object.get("hold") != null) {
        try waitForRelease(allocator, io, timers);
    }
    return .{ .string = name };
}

//
// A handler that sends an event and returns the task's name.
//
fn eventSendingTaskHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = timers;
    const name = data.object.get("name").?.string;
    context.sendEvent(io, allocator, log, try json(allocator, "{\"type\":\"note\"}"));
    return .{ .string = name };
}

//
// A handler that waits to be cancelled, for up to 30 seconds, and returns whether it saw the cancel.
//
fn cancellationCheckingHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = timers;
    _ = data;
    var attempts: usize = 0;
    while (!context.isCancelled(io, allocator) and attempts < 3000) : (attempts += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return .{ .bool = context.isCancelled(io, allocator) };
}

//
// A handler that fails.
//
fn failingHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: ILog, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = allocator;
    _ = io;
    _ = timers;
    _ = data;
    _ = context;
    return errors.throwError("task blew up", .{});
}

//
// Records the status, error message and output of every result it is given, in order.
//
const ResultRecorder = struct {
    // The statuses.
    statuses: std.ArrayList(TaskStatus),
    // The error message of each result ("" when there is none).
    errorMessages: std.ArrayList([]const u8),
    // The output of each result as JSON text ("null" when there is none).
    outputs: std.ArrayList([]const u8),

    const empty: ResultRecorder = .{
        .statuses = .empty,
        .errorMessages = .empty,
        .outputs = .empty,
    };

    //
    // The completion callback. The copies are allocated with the test thread's allocator, which it is given.
    //
    fn record(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, result: ITaskResult) anyerror!void {
        _ = log;
        _ = io;
        const self: *ResultRecorder = @ptrCast(@alignCast(context.?));
        try self.statuses.append(allocator, result.status);
        try self.errorMessages.append(allocator, try allocator.dupe(u8, if (result.@"error") |task_error| task_error.message else ""));
        try self.outputs.append(allocator, try std.json.Stringify.valueAlloc(allocator, result.outputs orelse .null, .{}));
    }
};

//
// Records the task ID of every event it is given, and the names in the "started" events.
//
const EventRecorder = struct {
    // The task IDs, in order.
    taskIds: std.ArrayList([]const u8),
    // The names of the tasks that sent "started", in order.
    started: std.ArrayList([]const u8),

    const empty: EventRecorder = .{
        .taskIds = .empty,
        .started = .empty,
    };

    //
    // The event callback.
    //
    fn record(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, data: ITaskEventData) anyerror!void {
        _ = log;
        _ = io;
        const self: *EventRecorder = @ptrCast(@alignCast(context.?));
        // The task ID is valid only during the call, so the recorder keeps a copy.
        try self.taskIds.append(allocator, try allocator.dupe(u8, data.taskId));
        const event_type = ziggy.json.getString(data.event, "type") orelse "";
        if (std.mem.eql(u8, event_type, "started")) {
            try self.started.append(allocator, try allocator.dupe(u8, ziggy.json.getString(data.event, "name") orelse ""));
        }
    }

    //
    // Whether a task of the name has sent "started".
    //
    fn sawStart(self: *const EventRecorder, name: []const u8) bool {
        for (self.started.items) |started| {
            if (std.mem.eql(u8, started, name)) {
                return true;
            }
        }
        return false;
    }
};

//
// Waits until the pool has sent every task it has to a worker and the first of them has started, reading the pool's messages meanwhile.
//
fn waitUntilRunning(io: std.Io, allocator: std.mem.Allocator, timers: Timers, pool: *MockWorkerPool) void {
    const console_log = MuteLog.init();
    while (pool.pool.pending_tasks.items.len > 0) {
        pool.waitForMessage(io, allocator, timers, console_log);
    }
}

//
// Completes the "other-source" queue's part in a test: cancels the source named in the context when a task of that queue completes,
// which runs while the test thread waits on its own queue.
//
fn cancelSourceOnComplete(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, result: ITaskResult) anyerror!void {
    const console_log = MuteLog.init();
    _ = log;
    _ = result;
    const target: *SourceCancel = @ptrCast(@alignCast(context.?));
    target.pool.cancelTasks(io, allocator, console_log, target.source);
}

//
// Which pool and source cancelSourceOnComplete cancels.
//
const SourceCancel = struct {
    // The pool.
    pool: *MockWorkerPool,
    // The source.
    source: []const u8,
};

//
// Shuts a queue down when a task of another queue completes, which runs while the test thread waits on the queue.
//
fn shutDownOnComplete(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, log: ziggy.log.ILog, result: ITaskResult) anyerror!void {
    const console_log = MuteLog.init();
    _ = log;
    _ = result;
    const queue: *TaskQueue = @ptrCast(@alignCast(context.?));
    queue.shutdown(io, allocator, console_log);
}

//
// A pool of one worker running the task named "busy" of the queue of "busy-source", which takes the only slot and holds it until the
// test cancels `release_source`, so the next task is left waiting. This is the shape the tests below use to get a task that is running
// while another is queued. `events` records the queue's events.
//
fn withOneWorkerBusy(io: std.Io, allocator: std.mem.Allocator, timers: Timers, uuid_generator: utils.uuid_generator.IUuidGenerator, events: *EventRecorder) !struct { backend: *MockWorkerPool, queue: *TaskQueue } {
    const console_log = MuteLog.init();
    const backend = try MockWorkerPool.init(allocator, 1, base_context, &test_task_types);
    setQueueBackend(backend.queueBackend());
    const queue = try TaskQueue.init(allocator, uuid_generator, "busy-source");
    _ = try queue.onAnyTaskEvent(allocator, .{ .context = events, .function = EventRecorder.record });
    _ = try queue.addTask(io, allocator, console_log, "concurrency-task", try json(allocator, "{\"name\":\"busy\",\"hold\":true}"), null, null);
    // Waits until the busy task has taken the slot, so whatever is added next is definitely still waiting.
    while (!events.sawStart("busy")) {
        backend.waitForMessage(io, allocator, timers, console_log);
    }
    return .{ .backend = backend, .queue = queue };
}

test "a worker takes the next task as soon as the one it is running finishes" {
    const console_log = MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var events: EventRecorder = .empty;
    const busy = try withOneWorkerBusy(io, allocator, timers, uuid_generator.uuidGenerator(), &events);
    defer {
        busy.queue.deinit(io, allocator, console_log);
        setQueueBackend(null);
        busy.backend.deinit(io, allocator, timers, console_log);
    }
    var results: ResultRecorder = .empty;
    _ = try busy.queue.onTaskComplete(allocator, .{ .context = &results, .function = ResultRecorder.record });

    _ = try busy.queue.addTask(io, allocator, console_log, "concurrency-task", try json(allocator, "{\"name\":\"next\"}"), null, null);

    // The worker is busy, so the second task is waiting rather than running.
    const pendingBefore = try busy.backend.getPendingTaskTypes(allocator);
    try std.testing.expectEqual(@as(usize, 1), pendingBefore.len);
    try std.testing.expectEqualStrings("concurrency-task", pendingBefore[0]);
    try std.testing.expectEqual(@as(usize, 0), results.statuses.items.len);

    busy.backend.cancelTasks(io, allocator, console_log, release_source);
    try busy.queue.awaitAllTasks(io, allocator, timers, console_log);

    // It ran as soon as the slot was free, which is what a worker pool is for.
    try std.testing.expectEqual(@as(usize, 2), results.outputs.items.len);
    try std.testing.expectEqualStrings("\"busy\"", results.outputs.items[0]);
    try std.testing.expectEqualStrings("\"next\"", results.outputs.items[1]);
    try std.testing.expectEqual(@as(usize, 0), (try busy.backend.getPendingTaskTypes(allocator)).len);
}

test "a task that fails still hands the slot to the next task" {
    const console_log = MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var events: EventRecorder = .empty;
    const busy = try withOneWorkerBusy(io, allocator, timers, uuid_generator.uuidGenerator(), &events);
    defer {
        busy.queue.deinit(io, allocator, console_log);
        setQueueBackend(null);
        busy.backend.deinit(io, allocator, timers, console_log);
    }
    var results: ResultRecorder = .empty;
    _ = try busy.queue.onTaskComplete(allocator, .{ .context = &results, .function = ResultRecorder.record });

    // The failing task is queued behind the busy one, so it fails only once the slot is free.
    _ = try busy.queue.addTask(io, allocator, console_log, "concurrency-failing-task", try json(allocator, "{\"name\":\"failing\"}"), null, null);
    _ = try busy.queue.addTask(io, allocator, console_log, "concurrency-task", try json(allocator, "{\"name\":\"after-failure\"}"), null, null);

    busy.backend.cancelTasks(io, allocator, console_log, release_source);
    try busy.queue.awaitAllTasks(io, allocator, timers, console_log);

    // Three results: the busy task, then the failure, then the task queued behind it.
    try std.testing.expectEqual(@as(usize, 3), results.statuses.items.len);
    try std.testing.expectEqual(TaskStatus.Succeeded, results.statuses.items[0]);
    try std.testing.expectEqualStrings("\"busy\"", results.outputs.items[0]);
    try std.testing.expectEqual(TaskStatus.Failed, results.statuses.items[1]);
    try std.testing.expectEqualStrings("task blew up", results.errorMessages.items[1]);
    try std.testing.expectEqual(TaskStatus.Succeeded, results.statuses.items[2]);
    try std.testing.expectEqualStrings("\"after-failure\"", results.outputs.items[2]);
}

test "a running task sees that it has been cancelled" {
    const console_log = MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    const backend = try MockWorkerPool.init(allocator, 2, base_context, &test_task_types);
    setQueueBackend(backend.queueBackend());
    const queue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "cancel-source");
    defer {
        queue.deinit(io, allocator, console_log);
        setQueueBackend(null);
        backend.deinit(io, allocator, timers, console_log);
    }
    var results: ResultRecorder = .empty;
    _ = try queue.onTaskComplete(allocator, .{ .context = &results, .function = ResultRecorder.record });

    _ = try queue.addTask(io, allocator, console_log, "concurrency-cancellation-task", .null, null, null);

    // The task polls isCancelled, so cancelling the source once it runs is what it is waiting for.
    waitUntilRunning(io, allocator, timers, backend);
    backend.cancelTasks(io, allocator, console_log, "cancel-source");

    try queue.awaitAllTasks(io, allocator, timers, console_log);

    // The task saw the cancellation through its own context, which is the only way a handler learns it should stop.
    try std.testing.expectEqual(@as(usize, 1), results.outputs.items.len);
    try std.testing.expectEqualStrings("true", results.outputs.items[0]);
}

test "cancelTasks drops the waiting tasks of the cancelled source and leaves other sources alone" {
    const console_log = MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var events: EventRecorder = .empty;
    const busy = try withOneWorkerBusy(io, allocator, timers, uuid_generator.uuidGenerator(), &events);
    var other_queue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "other-source");
    defer {
        busy.queue.deinit(io, allocator, console_log);
        other_queue.deinit(io, allocator, console_log);
        setQueueBackend(null);
        busy.backend.deinit(io, allocator, timers, console_log);
    }
    var busy_results: ResultRecorder = .empty;
    _ = try busy.queue.onTaskComplete(allocator, .{ .context = &busy_results, .function = ResultRecorder.record });
    var other_results: ResultRecorder = .empty;
    _ = try other_queue.onTaskComplete(allocator, .{ .context = &other_results, .function = ResultRecorder.record });

    // Three waiting tasks: two of the cancelled source and one of another.
    _ = try busy.queue.addTask(io, allocator, console_log, "concurrency-task", try json(allocator, "{\"name\":\"cancelled-1\"}"), null, null);
    _ = try busy.queue.addTask(io, allocator, console_log, "concurrency-task", try json(allocator, "{\"name\":\"cancelled-2\"}"), null, null);
    _ = try other_queue.addTask(io, allocator, console_log, "concurrency-task", try json(allocator, "{\"name\":\"other\"}"), null, null);
    try std.testing.expectEqual(@as(usize, 3), (try busy.backend.getPendingTaskTypes(allocator)).len);

    busy.backend.cancelTasks(io, allocator, console_log, "busy-source");

    // Only the other source's task is left waiting.
    const pendingAfter = try busy.backend.getPendingTaskTypes(allocator);
    try std.testing.expectEqual(@as(usize, 1), pendingAfter.len);

    busy.backend.cancelTasks(io, allocator, console_log, release_source);
    try other_queue.awaitAllTasks(io, allocator, timers, console_log);

    // The cancelled source's waiting tasks never ran; its running task and the other source's did.
    try std.testing.expectEqual(@as(usize, 1), busy_results.outputs.items.len);
    try std.testing.expectEqualStrings("\"busy\"", busy_results.outputs.items[0]);
    try std.testing.expectEqual(@as(usize, 1), other_results.outputs.items.len);
    try std.testing.expectEqualStrings("\"other\"", other_results.outputs.items[0]);
    try std.testing.expect(!events.sawStart("cancelled-1"));
    try std.testing.expect(!events.sawStart("cancelled-2"));
}

test "a task cancelled while it runs still reports its result, and its waiter was already given none" {
    const console_log = MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    // Two workers: the busy task holds one, and a task of another queue runs on the other while awaitTask waits.
    const backend = try MockWorkerPool.init(allocator, 2, base_context, &test_task_types);
    setQueueBackend(backend.queueBackend());
    const queue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "cancel-source");
    var other_queue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "other-source");
    defer {
        other_queue.deinit(io, allocator, console_log);
        queue.deinit(io, allocator, console_log);
        setQueueBackend(null);
        backend.deinit(io, allocator, timers, console_log);
    }

    var results: ResultRecorder = .empty;
    _ = try queue.onTaskComplete(allocator, .{ .context = &results, .function = ResultRecorder.record });
    const taskId = try queue.addTask(io, allocator, console_log, "concurrency-task", try json(allocator, "{\"name\":\"busy\",\"hold\":true}"), null, null);

    // Cancelling resolves the waiter with no result, because the task could still have failed or succeeded and the caller is told
    // nothing came of it. The cancel comes from the completion of the other queue's task, while awaitTask waits.
    var cancel: SourceCancel = .{
        .pool = backend,
        .source = "cancel-source",
    };
    _ = try other_queue.onTaskComplete(allocator, .{ .context = &cancel, .function = cancelSourceOnComplete });
    _ = try other_queue.addTask(io, allocator, console_log, "concurrency-task", try json(allocator, "{\"name\":\"other\"}"), null, null);
    const outcome = try queue.awaitTask(io, allocator, timers, console_log, taskId);
    try std.testing.expect(outcome == null);

    // The task was already running, so cancelling does not stop it: it finishes and reports.
    backend.cancelTasks(io, allocator, console_log, release_source);

    // Nothing is awaiting the result now (the waiter was resolved by the cancel), so the queue's
    // callbacks run when the thread next waits on it.
    _ = try queue.addTask(io, allocator, console_log, "concurrency-task", try json(allocator, "{\"name\":\"after-cancel\"}"), null, null);
    try queue.awaitAllTasks(io, allocator, timers, console_log);

    try std.testing.expectEqual(@as(usize, 2), results.statuses.items.len);
    try std.testing.expectEqual(TaskStatus.Succeeded, results.statuses.items[0]);
    try std.testing.expectEqual(TaskStatus.Succeeded, results.statuses.items[1]);
}

test "shutdown drops the tasks still waiting for a slot" {
    const console_log = MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var events: EventRecorder = .empty;
    const busy = try withOneWorkerBusy(io, allocator, timers, uuid_generator.uuidGenerator(), &events);
    defer {
        busy.queue.deinit(io, allocator, console_log);
        setQueueBackend(null);
        busy.backend.deinit(io, allocator, timers, console_log);
    }
    // Every result the pool gives, whichever queue it is for.
    var results: ResultRecorder = .empty;
    _ = try busy.backend.queueBackend().onTaskComplete(allocator, .{ .context = &results, .function = ResultRecorder.record });
    _ = try busy.queue.addTask(io, allocator, console_log, "concurrency-task", try json(allocator, "{\"name\":\"dropped\"}"), null, null);
    try std.testing.expectEqual(@as(usize, 1), (try busy.backend.getPendingTaskTypes(allocator)).len);

    // Shutting the queue down cancels the backend's tasks of its source, which takes the waiting one
    // with it and leaves the running one to finish on its own.
    busy.queue.shutdown(io, allocator, console_log);
    try std.testing.expectEqual(@as(usize, 0), (try busy.backend.getPendingTaskTypes(allocator)).len);

    busy.backend.cancelTasks(io, allocator, console_log, release_source);
    while (busy.backend.pool.isBusy()) {
        busy.backend.waitForMessage(io, allocator, timers, console_log);
    }
    try std.testing.expectEqual(@as(usize, 1), results.outputs.items.len);
    try std.testing.expectEqualStrings("\"busy\"", results.outputs.items[0]);
}

//
// A backend that counts how many times each of the calls that shut a queue down is made, so that the
// tests can tell a second cancel apart from a first one.
//
const CountingBackend = struct {
    // How many times cancelTasks has been called.
    cancelTasksCalls: u32,

    // The sources cancelTasks was called with, in order (copied, because the queue frees its own
    // copy of its source when it is freed).
    cancelledSources: [4][32]u8,

    // The number of bytes of each recorded source that are valid.
    cancelledSourceLengths: [4]usize,

    // How many entries of cancelledSources are valid.
    cancelledCount: usize,

    // How many times shutdown has been called.
    shutdownCalls: u32,

    //
    // Gets the IQueueBackend interface for this backend.
    //
    fn queueBackend(self: *CountingBackend) IQueueBackend {
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
    // Returns the task ID it was given.
    //
    fn addTask(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, log: ziggy.log.ILog, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?types.TaskPriority) anyerror![]const u8 {
        _ = log;
        _ = ptr;
        _ = io;
        _ = @"type";
        _ = data;
        _ = source;
        _ = priority;
        return try allocator.dupe(u8, taskId orelse "task-id");
    }

    //
    // Does nothing.
    //
    fn noUnsubscribe(context: ?*anyopaque, allocator: std.mem.Allocator, key: usize) void {
        _ = context;
        _ = allocator;
        _ = key;
    }

    //
    // An unsubscribe function that does nothing.
    //
    const no_unsubscribe: types.UnsubscribeFn = .{ .context = null, .key = 0, .function = noUnsubscribe };

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTaskAdded(ptr: *anyopaque, allocator: std.mem.Allocator, source: []const u8, callback: types.TaskAddedCallback) anyerror!types.UnsubscribeFn {
        _ = ptr;
        _ = allocator;
        _ = source;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTaskComplete(ptr: *anyopaque, allocator: std.mem.Allocator, callback: types.WorkerTaskCompletionCallback) anyerror!types.UnsubscribeFn {
        _ = ptr;
        _ = allocator;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTaskEvent(ptr: *anyopaque, allocator: std.mem.Allocator, eventType: []const u8, callback: types.TaskEventCallback) anyerror!types.UnsubscribeFn {
        _ = ptr;
        _ = allocator;
        _ = eventType;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onAnyTaskEvent(ptr: *anyopaque, allocator: std.mem.Allocator, callback: types.TaskEventCallback) anyerror!types.UnsubscribeFn {
        _ = ptr;
        _ = allocator;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Records the source.
    //
    fn cancelTasks(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, log: ziggy.log.ILog, source: []const u8) void {
        _ = log;
        _ = io;
        _ = allocator;
        const self: *CountingBackend = @ptrCast(@alignCast(ptr));
        self.cancelTasksCalls += 1;
        if (self.cancelledCount < self.cancelledSources.len) {
            @memcpy(self.cancelledSources[self.cancelledCount][0..source.len], source);
            self.cancelledSourceLengths[self.cancelledCount] = source.len;
            self.cancelledCount += 1;
        }
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTasksCancelled(ptr: *anyopaque, allocator: std.mem.Allocator, source: []const u8, callback: types.TasksCancelledCallback) anyerror!types.UnsubscribeFn {
        _ = ptr;
        _ = allocator;
        _ = source;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Counts the call.
    //
    fn shutdown(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        _ = io;
        _ = allocator;
        const self: *CountingBackend = @ptrCast(@alignCast(ptr));
        self.shutdownCalls += 1;
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
        @panic("the counting backend has no messages to wait for");
    }
};

test "deinit after an explicit shutdown does not cancel the source a second time" {
    const console_log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var backend: CountingBackend = .{
        .cancelTasksCalls = 0,
        .cancelledSources = undefined,
        .cancelledSourceLengths = undefined,
        .cancelledCount = 0,
        .shutdownCalls = 0,
    };
    setQueueBackend(backend.queueBackend());
    const queue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "counted-source");

    queue.shutdown(io, allocator, console_log);
    queue.shutdown(io, allocator, console_log);
    queue.deinit(io, allocator, console_log);

    // Repeated shutdowns and the deinit that follows them are two cancels of the source, not three:
    // the deinit must not signal every running task a second time.
    try std.testing.expectEqual(@as(u32, 2), backend.cancelTasksCalls);

    // The queue never shuts the backend down itself: that is the process's call, not a queue's.
    try std.testing.expectEqual(@as(u32, 0), backend.shutdownCalls);

    setQueueBackend(null);
}

test "deinit on a queue that was never shut down cancels the source once" {
    const console_log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var backend: CountingBackend = .{
        .cancelTasksCalls = 0,
        .cancelledSources = undefined,
        .cancelledSourceLengths = undefined,
        .cancelledCount = 0,
        .shutdownCalls = 0,
    };
    setQueueBackend(backend.queueBackend());
    const queue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "counted-source");

    queue.deinit(io, allocator, console_log);

    // Nothing else shut it down, so deinit is what cancels the source. Without that, freeing a queue
    // would leave its tasks running with nobody waiting for them.
    try std.testing.expectEqual(@as(u32, 1), backend.cancelTasksCalls);
    try std.testing.expectEqual(@as(usize, 1), backend.cancelledCount);
    try std.testing.expectEqualStrings("counted-source", backend.cancelledSources[0][0..backend.cancelledSourceLengths[0]]);
    try std.testing.expectEqual(@as(u32, 0), backend.shutdownCalls);

    setQueueBackend(null);
}

test "an event sent by a task of another source is not delivered" {
    const console_log = MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    const backend = try MockWorkerPool.init(allocator, 2, base_context, &test_task_types);
    setQueueBackend(backend.queueBackend());
    const queue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "event-source");
    var other_queue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "other-source");
    defer {
        queue.deinit(io, allocator, console_log);
        other_queue.deinit(io, allocator, console_log);
        setQueueBackend(null);
        backend.deinit(io, allocator, timers, console_log);
    }

    var events: EventRecorder = .empty;
    _ = try queue.onAnyTaskEvent(allocator, .{ .context = &events, .function = EventRecorder.record });
    var other_results: ResultRecorder = .empty;
    _ = try other_queue.onTaskComplete(allocator, .{ .context = &other_results, .function = ResultRecorder.record });

    _ = try other_queue.addTask(io, allocator, console_log, "concurrency-event-task", try json(allocator, "{\"name\":\"other\"}"), null, null);
    try other_queue.awaitAllTasks(io, allocator, timers, console_log);
    try queue.awaitAllTasks(io, allocator, timers, console_log);

    // The task ran, but it belongs to a queue that did not add it, so its events are not this
    // queue's business.
    try std.testing.expectEqual(@as(usize, 1), other_results.outputs.items.len);
    try std.testing.expectEqualStrings("\"other\"", other_results.outputs.items[0]);
    try std.testing.expectEqual(@as(usize, 0), events.taskIds.items.len);

    // The queue's own task does deliver.
    const ownTaskId = try queue.addTask(io, allocator, console_log, "concurrency-event-task", try json(allocator, "{\"name\":\"own\"}"), null, null);
    _ = try queue.awaitTask(io, allocator, timers, console_log, ownTaskId);
    try std.testing.expectEqual(@as(usize, 1), events.taskIds.items.len);
    try std.testing.expectEqualStrings(ownTaskId, events.taskIds.items[0]);
}

test "a task with no registered handler fails with the worker's message" {
    const console_log = MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    const backend = try MockWorkerPool.init(allocator, 2, base_context, &test_task_types);
    setQueueBackend(backend.queueBackend());
    const queue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "unhandled-source");
    defer {
        queue.deinit(io, allocator, console_log);
        setQueueBackend(null);
        backend.deinit(io, allocator, timers, console_log);
    }

    var results: ResultRecorder = .empty;
    _ = try queue.onTaskComplete(allocator, .{ .context = &results, .function = ResultRecorder.record });

    // The pool's task types do not include this one, which is what a task queued for a feature that is not
    // wired up looks like. It must be reported as a failed task, not swallowed, with the worker's message for a task type it has no
    // handler for.
    _ = try queue.addTask(io, allocator, console_log, "concurrency-no-such-handler", .null, null, null);
    try queue.awaitAllTasks(io, allocator, timers, console_log);

    try std.testing.expectEqual(@as(usize, 1), results.statuses.items.len);
    try std.testing.expectEqual(TaskStatus.Failed, results.statuses.items[0]);
    try std.testing.expectEqualStrings("UnknownTaskType", results.errorMessages.items[0]);
}

test "shutdown while a task is running resolves a waiter and the task still finishes" {
    const console_log = MuteLog.init();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    // Two workers: the busy task holds one, and a task of another queue runs on the other while awaitAllTasks waits.
    const backend = try MockWorkerPool.init(allocator, 2, base_context, &test_task_types);
    setQueueBackend(backend.queueBackend());
    const queue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "shutdown-source");
    var other_queue = try TaskQueue.init(allocator, uuid_generator.uuidGenerator(), "other-source");
    defer {
        other_queue.deinit(io, allocator, console_log);
        queue.deinit(io, allocator, console_log);
        setQueueBackend(null);
        backend.deinit(io, allocator, timers, console_log);
    }

    var results: ResultRecorder = .empty;
    _ = try queue.onTaskComplete(allocator, .{ .context = &results, .function = ResultRecorder.record });
    // Every result the pool gives, whichever queue it is for, to see the busy task finish.
    var all_results: ResultRecorder = .empty;
    _ = try backend.queueBackend().onTaskComplete(allocator, .{ .context = &all_results, .function = ResultRecorder.record });
    _ = try queue.addTask(io, allocator, console_log, "concurrency-task", try json(allocator, "{\"name\":\"busy\",\"hold\":true}"), null, null);

    // The queue is shut down by the completion of the other queue's task, while awaitAllTasks waits, which then returns.
    _ = try other_queue.onTaskComplete(allocator, .{ .context = queue, .function = shutDownOnComplete });
    _ = try other_queue.addTask(io, allocator, console_log, "concurrency-task", try json(allocator, "{\"name\":\"other\"}"), null, null);
    try queue.awaitAllTasks(io, allocator, timers, console_log);
    backend.cancelTasks(io, allocator, console_log, release_source);
    // Waits for the busy task to finish, so its result has arrived before the recorders are read.
    while (backend.pool.isBusy()) {
        backend.waitForMessage(io, allocator, timers, console_log);
    }

    // The task kept running and finished, but its result reaches nobody: the queue unsubscribed from
    // the backend before the result arrived.
    try std.testing.expectEqual(@as(usize, 0), results.statuses.items.len);
    try std.testing.expectEqual(@as(usize, 2), all_results.outputs.items.len);
    try std.testing.expectEqualStrings("\"busy\"", all_results.outputs.items[1]);
}
