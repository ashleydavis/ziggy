//
// IQueueBackend: the interface that all task scheduling backends implement.
// Real worker pools and IPC/WebSocket proxies implement this.
// TaskQueue depends only on IQueueBackend; each thread that queues tasks registers its backend once
// with setQueueBackend(): a worker registers the backend that sends its child tasks to the main thread,
// and the main thread registers its worker pool.
//
// Threading contract:
// - A backend is used only on the thread that registered it.
// - Callbacks fire on that thread, while it reads its messages (see waitForMessage), but the callbacks
//   registered for a task added with addTask must fire before addTask returns (TaskQueue relies on
//   onTaskAdded being called synchronously from addTask).
// - After an UnsubscribeFn returns, the backend must not invoke that callback again.
// - Values passed to callbacks only have to stay valid during the call.
//

const std = @import("std");
const utils = @import("utils");
const ILog = @import("log").ILog;
const types = @import("types.zig");
const Timers = @import("../timers.zig").Timers;
const WorkerTaskCompletionCallback = types.WorkerTaskCompletionCallback;
const TaskEventCallback = types.TaskEventCallback;
const UnsubscribeFn = types.UnsubscribeFn;
const TaskAddedCallback = types.TaskAddedCallback;
const TasksCancelledCallback = types.TasksCancelledCallback;
const TaskPriority = types.TaskPriority;
const errors = utils.errors;

//
// The interface implemented by all queue backends.
// Worker pools implement this plus IWorkerPool. IPC/WebSocket proxies implement only this.
//
pub const IQueueBackend = struct {
    // Pointer to the implementation.
    ptr: *anyopaque,

    // The implementation's functions.
    vtable: *const VTable,

    //
    // The functions an implementation of IQueueBackend provides. Each is given the Io and the allocator of the calling thread where
    // it needs them, and the backend keeps neither.
    //
    pub const VTable = struct {
        // Adds a task to the backend. Returns the task ID (allocated with allocator).
        addTask: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, log: ILog, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) anyerror![]const u8,

        // Registers a callback that fires whenever a task with the given source is added.
        onTaskAdded: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, source: []const u8, callback: TaskAddedCallback) anyerror!UnsubscribeFn,

        // Registers a callback that fires when any task completes (success or failure).
        onTaskComplete: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, callback: WorkerTaskCompletionCallback) anyerror!UnsubscribeFn,

        // Registers a callback for task events of a specific type.
        onTaskEvent: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, eventType: []const u8, callback: TaskEventCallback) anyerror!UnsubscribeFn,

        // Registers a callback for every task event regardless of type.
        onAnyTaskEvent: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, callback: TaskEventCallback) anyerror!UnsubscribeFn,

        // Signals running tasks with the given source to cancel and drops pending tasks with that source.
        cancelTasks: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, log: ILog, source: []const u8) void,

        // Registers a callback that fires when cancelTasks is called for the given source.
        onTasksCancelled: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, source: []const u8, callback: TasksCancelledCallback) anyerror!UnsubscribeFn,

        // Shuts down the backend, releasing all resources.
        shutdown: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void,

        // Reads the thread's next message, waiting for one no longer than until the thread's next timer is due, and runs the timers
        // that are due, so the callbacks of a task that ended or sent an event fire.
        waitForMessage: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog) void,
    };

    //
    // Adds a task to the backend. Returns the task ID.
    // If taskId is provided it is used instead of generating a new one.
    //
    // The priority decides which pending task is dispatched next. Leaving it out means "whatever is
    // right for this task": a task queued from inside a running task runs at its parent's priority,
    // so an import's children can never overtake something the user is waiting on, and anything else
    // runs at DEFAULT_TASK_PRIORITY. Pass it explicitly to mark that the user is waiting (Interactive), or
    // to opt a child back down to Background when it is long-running work its parent only kicked off.
    //
    // The backend copies `data` (it only has to be valid during the call).
    //
    pub fn addTask(self: IQueueBackend, allocator: std.mem.Allocator, io: std.Io, log: ILog, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) anyerror![]const u8 {
        return self.vtable.addTask(self.ptr, allocator, io, log, @"type", data, source, taskId, priority);
    }

    //
    // Registers a callback that fires whenever a task with the given source is added.
    // Returns an unsubscribe function.
    //
    pub fn onTaskAdded(self: IQueueBackend, allocator: std.mem.Allocator, source: []const u8, callback: TaskAddedCallback) anyerror!UnsubscribeFn {
        return self.vtable.onTaskAdded(self.ptr, allocator, source, callback);
    }

    //
    // Registers a callback that fires when any task completes (success or failure).
    // Returns an unsubscribe function.
    //
    pub fn onTaskComplete(self: IQueueBackend, allocator: std.mem.Allocator, callback: WorkerTaskCompletionCallback) anyerror!UnsubscribeFn {
        return self.vtable.onTaskComplete(self.ptr, allocator, callback);
    }

    //
    // Registers a callback for task events of a specific type.
    // Returns an unsubscribe function.
    //
    pub fn onTaskEvent(self: IQueueBackend, allocator: std.mem.Allocator, eventType: []const u8, callback: TaskEventCallback) anyerror!UnsubscribeFn {
        return self.vtable.onTaskEvent(self.ptr, allocator, eventType, callback);
    }

    //
    // Registers a callback for every task event regardless of type.
    // Returns an unsubscribe function.
    //
    pub fn onAnyTaskEvent(self: IQueueBackend, allocator: std.mem.Allocator, callback: TaskEventCallback) anyerror!UnsubscribeFn {
        return self.vtable.onAnyTaskEvent(self.ptr, allocator, callback);
    }

    //
    // Signals running tasks with the given source to cancel and drops any pending
    // tasks with that source from the queue.
    //
    pub fn cancelTasks(self: IQueueBackend, io: std.Io, allocator: std.mem.Allocator, log: ILog, source: []const u8) void {
        self.vtable.cancelTasks(self.ptr, io, allocator, log, source);
    }

    //
    // Registers a callback that fires when cancelTasks is called for the given source.
    // Returns an unsubscribe function.
    //
    pub fn onTasksCancelled(self: IQueueBackend, allocator: std.mem.Allocator, source: []const u8, callback: TasksCancelledCallback) anyerror!UnsubscribeFn {
        return self.vtable.onTasksCancelled(self.ptr, allocator, source, callback);
    }

    //
    // Shuts down the backend, releasing all resources.
    //
    pub fn shutdown(self: IQueueBackend, io: std.Io, allocator: std.mem.Allocator) void {
        self.vtable.shutdown(self.ptr, io, allocator);
    }

    //
    // Reads the thread's next message, waiting for one no longer than until the thread's next timer is due, and runs the timers that
    // are due, so the callbacks of a task that ended or sent an event fire. A TaskQueue waits for its tasks with it.
    //
    pub fn waitForMessage(self: IQueueBackend, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog) void {
        self.vtable.waitForMessage(self.ptr, io, allocator, timers, log);
    }
};


//
// The backend of the calling thread, set once when the thread starts via setQueueBackend(). Each thread
// has its own: a worker's sends child tasks to the main thread, and the main thread's is its worker pool.
//
threadlocal var _backend: ?IQueueBackend = null;

//
// Registers the queue backend of the calling thread.
// Must be called on the thread before any TaskQueue is created on it.
// (It takes an optional so that tests can clear it.)
//
pub fn setQueueBackend(backend: ?IQueueBackend) void {
    _backend = backend;
}

//
// Returns the queue backend of the calling thread.
// Throws if setQueueBackend() has not been called on it.
//
pub fn getQueueBackend() !IQueueBackend {
    if (_backend) |backend| {
        return backend;
    }
    return errors.throwError("Queue backend not initialised \u{2014} call setQueueBackend() at process startup.", .{});
}
