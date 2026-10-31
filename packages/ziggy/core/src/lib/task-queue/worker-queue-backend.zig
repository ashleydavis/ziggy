//
// Worker-side queue backend, for use on a worker's thread. A port of the TypeScript WorkerQueueBackend
// (worker-queue-backend.ts of the TypeScript task-queue package): it sends the child tasks a task queues to the main thread as
// "queue-task" messages, and fires its completion callbacks when the worker reads the "task-completed" message the main thread
// sends back for one of them.
//
// Everything here runs on the worker's thread: the callbacks fire while the worker reads its messages, so nothing is locked. The
// backend keeps no Io, allocator or timers: each function is given the worker thread's, and its registrations are allocated with the
// allocator the task's handler was given, which every task queue of the task must be given too, and forgotten when the task ends (see
// `forgetAll`).
//

const std = @import("std");
const utils = @import("utils");
const ziggy_log = @import("log");
const types = @import("types.zig");
const queue_backend = @import("queue-backend.zig");
const Timers = @import("../timers.zig").Timers;
const IQueueBackend = queue_backend.IQueueBackend;
const ITaskResult = types.ITaskResult;
const ITaskEventData = types.ITaskEventData;
const TaskPriority = types.TaskPriority;
const UnsubscribeFn = types.UnsubscribeFn;
const WorkerTaskCompletionCallback = types.WorkerTaskCompletionCallback;
const TaskEventCallback = types.TaskEventCallback;
const IEventCallbackEntry = types.IEventCallbackEntry;
const TaskAddedCallback = types.TaskAddedCallback;
const TasksCancelledCallback = types.TasksCancelledCallback;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ILog = ziggy_log.log.ILog;

//
// Sends a message to the main thread: the worker's `parentPort.postMessage`.
//
pub const PostMessageFn = struct {
    // The function's own pointer, passed back on every call.
    context: ?*anyopaque,
    // Sends a copy of the JSON text, with the worker thread's Io.
    function: *const fn (context: ?*anyopaque, io: std.Io, text: []const u8) anyerror!void,
};

//
// Reads the worker's next message, waiting for one no longer than until the worker's next timer is due, so the callbacks of a task
// that ended fire.
//
pub const WaitForMessageFn = struct {
    // The function's own pointer, passed back on every call.
    context: ?*anyopaque,
    // Reads one message, with the worker thread's Io, allocator and timers.
    function: *const fn (context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers) void,
};

//
// A callback and the key that identifies it for unsubscribing, with the source it was registered for ("" when it is not for one source).
//
fn Registration(comptime CallbackT: type) type {
    return struct {
        // Identifies the registration.
        key: usize,
        // The source the callback is for, owned by the backend.
        source: []u8,
        // The callback.
        callback: CallbackT,
    };
}

//
// The keys of the registrations of a list, copied with the allocator, which the caller frees them with. A callback may register or
// unregister callbacks while the callbacks of a list are called, so they are called by these keys rather than by their places in the
// list, as Node's EventEmitter calls the listeners it had when an event was emitted.
//
fn callbackKeys(allocator: std.mem.Allocator, list: anytype) ![]usize {
    const keys = try allocator.alloc(usize, list.items.len);
    for (list.items, keys) |registration, *key| {
        key.* = registration.key;
    }
    return keys;
}

//
// The registration of a list with the key, or null when it has been unregistered.
//
fn registered(list: anytype, key: usize) ?@TypeOf(list.items[0]) {
    for (list.items) |registration| {
        if (registration.key == key) {
            return registration;
        }
    }
    return null;
}

//
// IQueueBackend implementation for a worker's thread.
//
pub const WorkerQueueBackend = struct {
    // Sends messages to the main thread.
    postMessage: PostMessageFn,
    // Reads the worker's next message.
    waitForMessageFn: WaitForMessageFn,
    // Generates the ids of tasks added without one.
    uuidGenerator: IUuidGenerator,
    // The key of the next registration.
    nextKey: usize,
    // Callbacks invoked when any child task completes.
    completionCallbacks: std.ArrayList(Registration(WorkerTaskCompletionCallback)),
    // Callbacks invoked for task events of a specific type.
    eventCallbacks: std.ArrayList(Registration(IEventCallbackEntry)),
    // Callbacks invoked for all task events.
    anyEventCallbacks: std.ArrayList(Registration(TaskEventCallback)),
    // Per-source callbacks fired when addTask is called for that source.
    taskAddedCallbacks: std.ArrayList(Registration(TaskAddedCallback)),
    // Per-source callbacks fired when cancelTasks is called for that source.
    tasksCancelledCallbacks: std.ArrayList(Registration(TasksCancelledCallback)),

    //
    // Makes the backend.
    //
    pub fn init(postMessage: PostMessageFn, waitForMessageFunction: WaitForMessageFn, uuidGenerator: IUuidGenerator) WorkerQueueBackend {
        return .{
            .postMessage = postMessage,
            .waitForMessageFn = waitForMessageFunction,
            .uuidGenerator = uuidGenerator,
            .nextKey = 0,
            .completionCallbacks = .empty,
            .eventCallbacks = .empty,
            .anyEventCallbacks = .empty,
            .taskAddedCallbacks = .empty,
            .tasksCancelledCallbacks = .empty,
        };
    }

    //
    // Releases the registrations, with the worker thread's allocator.
    //
    pub fn deinit(self: *WorkerQueueBackend, allocator: std.mem.Allocator) void {
        freeList(allocator, &self.completionCallbacks);
        freeList(allocator, &self.eventCallbacks);
        freeList(allocator, &self.anyEventCallbacks);
        freeList(allocator, &self.taskAddedCallbacks);
        freeList(allocator, &self.tasksCancelledCallbacks);
    }

    //
    // Forgets every registration without freeing it, for registrations made with an allocator that is freed on its own, as a task's
    // arena is when the task ends.
    //
    pub fn forgetAll(self: *WorkerQueueBackend) void {
        self.completionCallbacks = .empty;
        self.eventCallbacks = .empty;
        self.anyEventCallbacks = .empty;
        self.taskAddedCallbacks = .empty;
        self.tasksCancelledCallbacks = .empty;
    }

    //
    // Frees the sources a list of registrations owns, and the list.
    //
    fn freeList(allocator: std.mem.Allocator, list: anytype) void {
        for (list.items) |registration| {
            allocator.free(registration.source);
        }
        list.deinit(allocator);
    }

    //
    // Gets the IQueueBackend interface for this backend.
    //
    pub fn queueBackend(self: *WorkerQueueBackend) IQueueBackend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IQueueBackend functions of this backend.
    //
    const vtable: IQueueBackend.VTable = .{
        .addTask = addTaskErased,
        .onTaskAdded = onTaskAddedErased,
        .onTaskComplete = onTaskCompleteErased,
        .onTaskEvent = onTaskEventErased,
        .onAnyTaskEvent = onAnyTaskEventErased,
        .cancelTasks = cancelTasksErased,
        .onTasksCancelled = onTasksCancelledErased,
        .shutdown = shutdownErased,
        .waitForMessage = waitForMessageErased,
    };

    //
    // Sends a "queue-task" message to the main thread and fires the onTaskAdded callbacks of the source.
    //
    // The priority travels with the message but is only a request: the main thread knows which task queued this one, so an omitted
    // priority becomes that task's, which is what stops an import's children overtaking work the user is waiting on.
    //
    pub fn addTask(self: *WorkerQueueBackend, allocator: std.mem.Allocator, io: std.Io, log: ILog, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) ![]const u8 {
        const id = if (taskId) |given| try allocator.dupe(u8, given) else try self.uuidGenerator.generate(allocator, io);
        const message = try std.json.Stringify.valueAlloc(allocator, .{
            .type = "queue-task",
            .taskId = id,
            .taskType = @"type",
            .data = data,
            .source = source,
            .priority = priority,
        }, .{
            .emit_null_optional_fields = false,
        });
        defer allocator.free(message);
        try self.postMessage.function(self.postMessage.context, io, message);
        const keys = try callbackKeys(allocator, &self.taskAddedCallbacks);
        defer allocator.free(keys);
        for (keys) |key| {
            const registration = registered(&self.taskAddedCallbacks, key) orelse {
                continue;
            };
            if (std.mem.eql(u8, registration.source, source)) {
                registration.callback.call(allocator, log, id);
            }
        }
        return id;
    }

    //
    // Registers a callback that fires when a task with the given source is added.
    //
    pub fn onTaskAdded(self: *WorkerQueueBackend, allocator: std.mem.Allocator, source: []const u8, callback: TaskAddedCallback) !UnsubscribeFn {
        return self.register(allocator, TaskAddedCallback, &self.taskAddedCallbacks, source, callback);
    }

    //
    // Registers a callback that fires when any child task completes.
    //
    pub fn onTaskComplete(self: *WorkerQueueBackend, allocator: std.mem.Allocator, callback: WorkerTaskCompletionCallback) !UnsubscribeFn {
        return self.register(allocator, WorkerTaskCompletionCallback, &self.completionCallbacks, "", callback);
    }

    //
    // Registers a callback for child task events of a specific type.
    //
    pub fn onTaskEvent(self: *WorkerQueueBackend, allocator: std.mem.Allocator, eventType: []const u8, callback: TaskEventCallback) !UnsubscribeFn {
        return self.register(allocator, IEventCallbackEntry, &self.eventCallbacks, "", .{
            .eventType = eventType,
            .callback = callback,
        });
    }

    //
    // Registers a callback for all child task events regardless of type.
    //
    pub fn onAnyTaskEvent(self: *WorkerQueueBackend, allocator: std.mem.Allocator, callback: TaskEventCallback) !UnsubscribeFn {
        return self.register(allocator, TaskEventCallback, &self.anyEventCallbacks, "", callback);
    }

    //
    // Fires onTasksCancelled callbacks for the given source. Called when the worker reads a "cancel-tasks" message.
    //
    pub fn cancelTasks(self: *WorkerQueueBackend, io: std.Io, allocator: std.mem.Allocator, log: ILog, source: []const u8) void {
        _ = log;
        const keys = callbackKeys(allocator, &self.tasksCancelledCallbacks) catch @panic("out of memory calling callbacks");
        defer allocator.free(keys);
        for (keys) |key| {
            const registration = registered(&self.tasksCancelledCallbacks, key) orelse {
                continue;
            };
            if (std.mem.eql(u8, registration.source, source)) {
                registration.callback.call(io, allocator);
            }
        }
    }

    //
    // Registers a callback that fires when cancelTasks is called for the given source.
    //
    pub fn onTasksCancelled(self: *WorkerQueueBackend, allocator: std.mem.Allocator, source: []const u8, callback: TasksCancelledCallback) !UnsubscribeFn {
        return self.register(allocator, TasksCancelledCallback, &self.tasksCancelledCallbacks, source, callback);
    }

    //
    // Reads the worker's next message, so the callbacks of a task that ended fire.
    //
    pub fn waitForMessage(self: *WorkerQueueBackend, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog) void {
        // The worker reads its messages with its own log, which is the log the caller was given.
        _ = log;
        self.waitForMessageFn.function(self.waitForMessageFn.context, io, allocator, timers);
    }

    //
    // Fires all registered onTaskComplete callbacks with the given result. Called when the worker reads a "task-completed" message.
    //
    pub fn notifyTaskCompleted(self: *WorkerQueueBackend, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog, result: ITaskResult) !void {
        const keys = try callbackKeys(allocator, &self.completionCallbacks);
        defer allocator.free(keys);
        for (keys) |key| {
            const registration = registered(&self.completionCallbacks, key) orelse {
                continue;
            };
            try registration.callback.call(io, allocator, timers, log, result);
        }
    }

    //
    // Fires all registered onTaskEvent / onAnyTaskEvent callbacks for a child task's event.
    //
    pub fn notifyTaskMessage(self: *WorkerQueueBackend, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog, taskId: []const u8, message: std.json.Value) !void {
        const eventType = types.eventTypeOf(message);
        const data: ITaskEventData = .{
            .taskId = taskId,
            .event = message,
        };
        const event_keys = try callbackKeys(allocator, &self.eventCallbacks);
        defer allocator.free(event_keys);
        for (event_keys) |key| {
            const registration = registered(&self.eventCallbacks, key) orelse {
                continue;
            };
            if (eventType == null or !std.mem.eql(u8, eventType.?, registration.callback.eventType)) {
                continue;
            }
            try registration.callback.callback.call(io, allocator, timers, log, data);
        }
        const any_keys = try callbackKeys(allocator, &self.anyEventCallbacks);
        defer allocator.free(any_keys);
        for (any_keys) |key| {
            const registration = registered(&self.anyEventCallbacks, key) orelse {
                continue;
            };
            try registration.callback.call(io, allocator, timers, log, data);
        }
    }

    //
    // Adds a registration to a callback list and returns the function that removes it.
    //
    fn register(self: *WorkerQueueBackend, allocator: std.mem.Allocator, comptime CallbackT: type, list: *std.ArrayList(Registration(CallbackT)), source: []const u8, callback: CallbackT) !UnsubscribeFn {
        const source_copy = try allocator.dupe(u8, source);
        errdefer allocator.free(source_copy);
        const key = self.nextKey;
        self.nextKey += 1;
        try list.append(allocator, .{
            .key = key,
            .source = source_copy,
            .callback = callback,
        });
        return .{
            .context = self,
            .key = key,
            .function = unregister,
        };
    }

    //
    // Removes the registration with the given key from whichever list holds it.
    //
    fn unregister(context: ?*anyopaque, allocator: std.mem.Allocator, key: usize) void {
        const self: *WorkerQueueBackend = @ptrCast(@alignCast(context.?));
        removeKey(allocator, TaskAddedCallback, &self.taskAddedCallbacks, key);
        removeKey(allocator, WorkerTaskCompletionCallback, &self.completionCallbacks, key);
        removeKey(allocator, IEventCallbackEntry, &self.eventCallbacks, key);
        removeKey(allocator, TaskEventCallback, &self.anyEventCallbacks, key);
        removeKey(allocator, TasksCancelledCallback, &self.tasksCancelledCallbacks, key);
    }

    //
    // Removes the registration with the given key from a list, if it is there.
    //
    fn removeKey(allocator: std.mem.Allocator, comptime CallbackT: type, list: *std.ArrayList(Registration(CallbackT)), key: usize) void {
        for (list.items, 0..) |registration, index| {
            if (registration.key == key) {
                allocator.free(registration.source);
                _ = list.orderedRemove(index);
                return;
            }
        }
    }

    fn addTaskErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, log: ILog, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) anyerror![]const u8 {
        const self: *WorkerQueueBackend = @ptrCast(@alignCast(ptr));
        return self.addTask(allocator, io, log, @"type", data, source, taskId, priority);
    }

    fn onTaskAddedErased(ptr: *anyopaque, allocator: std.mem.Allocator, source: []const u8, callback: TaskAddedCallback) anyerror!UnsubscribeFn {
        const self: *WorkerQueueBackend = @ptrCast(@alignCast(ptr));
        return self.onTaskAdded(allocator, source, callback);
    }

    fn onTaskCompleteErased(ptr: *anyopaque, allocator: std.mem.Allocator, callback: WorkerTaskCompletionCallback) anyerror!UnsubscribeFn {
        const self: *WorkerQueueBackend = @ptrCast(@alignCast(ptr));
        return self.onTaskComplete(allocator, callback);
    }

    fn onTaskEventErased(ptr: *anyopaque, allocator: std.mem.Allocator, eventType: []const u8, callback: TaskEventCallback) anyerror!UnsubscribeFn {
        const self: *WorkerQueueBackend = @ptrCast(@alignCast(ptr));
        return self.onTaskEvent(allocator, eventType, callback);
    }

    fn onAnyTaskEventErased(ptr: *anyopaque, allocator: std.mem.Allocator, callback: TaskEventCallback) anyerror!UnsubscribeFn {
        const self: *WorkerQueueBackend = @ptrCast(@alignCast(ptr));
        return self.onAnyTaskEvent(allocator, callback);
    }

    fn cancelTasksErased(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, log: ILog, source: []const u8) void {
        const self: *WorkerQueueBackend = @ptrCast(@alignCast(ptr));
        self.cancelTasks(io, allocator, log, source);
    }

    fn onTasksCancelledErased(ptr: *anyopaque, allocator: std.mem.Allocator, source: []const u8, callback: TasksCancelledCallback) anyerror!UnsubscribeFn {
        const self: *WorkerQueueBackend = @ptrCast(@alignCast(ptr));
        return self.onTasksCancelled(allocator, source, callback);
    }

    //
    // Does nothing: the worker's life is the main thread's to manage.
    //
    fn shutdownErased(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        _ = ptr;
        _ = io;
        _ = allocator;
    }

    fn waitForMessageErased(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog) void {
        const self: *WorkerQueueBackend = @ptrCast(@alignCast(ptr));
        self.waitForMessage(io, allocator, timers, log);
    }
};
