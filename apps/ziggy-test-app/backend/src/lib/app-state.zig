//
// What the test app keeps while it runs, and the parts of Ziggy that reach it: the state the backend holds for the app, the observers the
// backend calls when a task ends or sends an event, the describer that turns an error into the text of its reply, and messages that
// queue, cancel and announce work from the app's own code rather than from the frontend.
//

const std = @import("std");
const ziggy = @import("ziggy");

const Core = ziggy.core.Core;
const TaskContext = ziggy.task_runner.TaskContext;
const json = ziggy.json;

//
// The test app's state: counts of what the backend has told it about tasks.
//
pub const ExampleState = struct {
    // Guards the counts, which the observers update from the threads that run tasks.
    mutex: std.Io.Mutex,
    // The Io the mutex is used with.
    io: std.Io,
    // How many tasks have ended.
    tasks_ended: u64,
    // How many events tasks have sent.
    events_sent: u64,
    // Whether the backend has stopped the state, which it does before the task runner stops.
    stopped: bool,

    //
    // Takes the lock that guards the counts.
    //
    fn lock(self: *ExampleState) void {
        self.mutex.lockUncancelable(self.io);
    }

    //
    // Releases the lock that guards the counts.
    //
    fn unlock(self: *ExampleState) void {
        self.mutex.unlock(self.io);
    }
};

//
// The counts as the task-stats message and the describe-self task reply with them.
//
const TaskStats = struct {
    // How many tasks have ended.
    tasksEnded: u64,
    // How many events tasks have sent.
    eventsSent: u64,
};

//
// The state hooks the test app gives the backend.
//
pub const state_hooks = ziggy.core.AppState{
    .create = create,
    .stop = stop,
    .destroy = destroy,
};

//
// Makes the test app's state, with no tasks counted.
//
fn create(core: *Core) anyerror!*anyopaque {
    const state = try core.allocator.create(ExampleState);
    state.* = .{
        .mutex = .init,
        .io = core.io(),
        .tasks_ended = 0,
        .events_sent = 0,
        .stopped = false,
    };
    return state;
}

//
// Records that the backend has stopped the state. Nothing of the test app's runs by itself, so there is nothing else to stop.
//
fn stop(core: *Core, opaque_state: *anyopaque) void {
    _ = core;
    const state: *ExampleState = @ptrCast(@alignCast(opaque_state));
    state.lock();
    defer state.unlock();
    state.stopped = true;
}

//
// Releases the test app's state.
//
fn destroy(core: *Core, opaque_state: *anyopaque) void {
    const state: *ExampleState = @ptrCast(@alignCast(opaque_state));
    core.allocator.destroy(state);
}

//
// The test app's state, from the backend that holds it.
//
fn fromCore(core: *Core) *ExampleState {
    return @ptrCast(@alignCast(core.app_state.?));
}

//
// The counts, read under the lock.
//
fn readStats(state: *ExampleState) TaskStats {
    state.lock();
    defer state.unlock();
    return .{
        .tasksEnded = state.tasks_ended,
        .eventsSent = state.events_sent,
    };
}

//
// The backend's observer of a task that has ended: counts it.
//
pub fn onTaskEnd(core: *Core, end: ziggy.types.TaskEnd) void {
    _ = end;
    const state = fromCore(core);
    state.lock();
    defer state.unlock();
    state.tasks_ended += 1;
}

//
// The backend's observer of an event a task sent: counts it.
//
pub fn onTaskEvent(core: *Core, sent: ziggy.types.TaskSentEvent) void {
    _ = sent;
    const state = fromCore(core);
    state.lock();
    defer state.unlock();
    state.events_sent += 1;
}

//
// The data of task-stats and of refuse, which have none.
//
pub const NoRequest = struct {};

//
// Replies with how many tasks have ended and how many events tasks have sent since the app started.
//
pub fn taskStatsHandler(core: *Core, arena: std.mem.Allocator, request: NoRequest) !TaskStats {
    _ = arena;
    _ = request;
    return readStats(fromCore(core));
}

//
// Always fails with an error the test app's describer has a sentence for, so the frontend can check the sentence is what reaches it.
//
pub fn refuseHandler(core: *Core, arena: std.mem.Allocator, request: NoRequest) !void {
    _ = core;
    _ = arena;
    _ = request;
    return error.Refused;
}

//
// The test app's error describer: a sentence for the error the refuse message returns, and nothing for any other, which is then replied
// to by name.
//
pub fn describeError(err: anyerror) ?[]const u8 {
    if (err == error.Refused) {
        return "The test app refused, as it was asked to.";
    }
    return null;
}

//
// The data of queue-from-app and of cancel-from-app.
//
pub const SourceRequest = struct {
    // The source to queue the task under, or to cancel the tasks of.
    source: []const u8,
};

//
// Queues a hello-short task from the app's own code, under the source given in "source", and tells the frontend with an app event
// of the type "queued-from-app" that it did. The reply is the id of the task.
//
pub fn queueFromAppHandler(core: *Core, arena: std.mem.Allocator, request: SourceRequest) ![]const u8 {
    const task_id = try std.fmt.allocPrint(arena, "from-app-{s}", .{request.source});
    try core.runner.addTask(task_id, "hello-short", request.source, "null", .background, null);
    try core.sendEvent(arena, try json.stringify(arena, .{
        .type = "queued-from-app",
        .queued = task_id,
    }));
    return task_id;
}

//
// The message response to cancel-from-app, an empty object.
//
pub const CancelFromAppResponse = struct {};

//
// Cancels, from the app's own code, the tasks queued under the source given in "source".
//
pub fn cancelFromAppHandler(core: *Core, arena: std.mem.Allocator, request: SourceRequest) !CancelFromAppResponse {
    _ = arena;
    core.runner.cancelSource(request.source);
    return .{};
}

//
// Replies with what a task knows about itself from its context (its id, type and source, and the child task limit) and the counts the
// app's state holds, which it reaches through its context.
//
pub fn describeSelfHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const state: *ExampleState = @ptrCast(@alignCast(context.appState().?));
    return try json.stringify(context.arena, .{
        .taskId = context.taskId(),
        .taskType = context.taskType(),
        .source = context.source(),
        .maxConcurrentChildTasks = context.maxConcurrentChildTasks(),
        .stats = readStats(state),
    });
}

//
// Runs "children" hello-child tasks one after another, each freed as soon as it ends, and stops starting them once the task is cancelled,
// reporting in an output event how many it ran. Replies with how many ran and how each ended.
//
pub fn runInTurnHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const children = json.getInteger(data, "children") orelse 0;
    var statuses: std.ArrayList([]const u8) = .empty;
    var index: i64 = 0;
    while (index < children and !context.isCancelled()) : (index += 1) {
        // A cancel that lands while the child is being queued ends the call with error.Cancelled instead of a cancelled completion.
        const completion = context.runChild(context.arena, "hello-child", .{
            .index = index,
        }, null) catch |err| switch (err) {
            error.Cancelled => break,
            else => return err,
        };
        try statuses.append(context.arena, @tagName(completion.status));
    }
    if (context.isCancelled()) {
        try context.sendEvent(.{
            .type = "output",
            .text = try std.fmt.allocPrint(context.arena, "run-in-turn stopped after {d} children", .{statuses.items.len}),
        });
        return error.Cancelled;
    }
    return try json.stringify(context.arena, .{
        .ran = statuses.items.len,
        .statuses = statuses.items,
    });
}
