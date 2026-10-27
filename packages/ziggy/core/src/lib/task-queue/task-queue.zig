const std = @import("std");
const utils = @import("utils.zig");
const types = @import("types.zig");
const queue_backend = @import("queue-backend.zig");
const Timers = @import("../timers.zig").Timers;
const ITaskResult = types.ITaskResult;
const ITaskEventData = types.ITaskEventData;
const TaskEventCallback = types.TaskEventCallback;
const TaskCompletionCallback = types.TaskCompletionCallback;
const IEventCallbackEntry = types.IEventCallbackEntry;
const UnsubscribeFn = types.UnsubscribeFn;
const TaskPriority = types.TaskPriority;
const IQueueBackend = queue_backend.IQueueBackend;
const getQueueBackend = queue_backend.getQueueBackend;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ILog = utils.log.ILog;

//
// A caller waiting in awaitAllTasks.
//
const IAwaitAllResolver = struct {
    // Set when the caller can return.
    resolved: bool,
};

//
// A caller waiting in awaitTask.
//
const IAwaitTaskResolver = struct {
    // The task the caller waits for.
    taskId: []const u8,

    // The result of the task, allocated with the allocator of the thread that owns the queue, or null when the queue was shut down
    // or its tasks were cancelled.
    result: ?ITaskResult,

    // The error that prevented copying the result, if any.
    copyError: ?anyerror,

    // Set when the caller can return.
    resolved: bool,
};

//
// A completion callback with the key that identifies it for unsubscribing.
//
const ICompletionCallbackRegistration = struct {
    // Identifies the registration.
    key: usize,

    // The callback.
    callback: TaskCompletionCallback,
};

//
// An event callback entry with the key that identifies it for unsubscribing.
//
const IEventCallbackRegistration = struct {
    // Identifies the registration.
    key: usize,

    // The event type filter (owned by the queue) and the callback.
    entry: IEventCallbackEntry,
};

//
// A callback for every task event, with the key that identifies it for unsubscribing.
//
const IAnyEventCallbackRegistration = struct {
    // Identifies the registration.
    key: usize,

    // The callback.
    callback: TaskEventCallback,
};

//
// Generic task queue implementation with an abstraction for workers.
//
// Zig threading model: a queue is used on the thread that created it, with the backend that thread registered. The backend fires the
// queue's callbacks on that thread while the thread reads its messages, which awaitAllTasks and awaitTask do until what they wait for
// has happened. Values passed to callbacks are only valid during the call. The queue keeps no Io, allocator, timers or log: each function
// is given the calling thread's, and everything the queue holds is allocated with the allocator of the thread that owns it.
//
pub const TaskQueue = struct {
    //
    // Generates unique IDs for tasks added via addTask.
    //
    uuidGenerator: IUuidGenerator,

    //
    // Source tag used to identify all tasks owned by this queue instance.
    // Used for filtering completions and for cancellation via shutdown().
    //
    source: []const u8,

    //
    // The underlying backend that executes tasks (worker pool or the worker's backend).
    //
    backend: IQueueBackend,

    //
    // Callbacks invoked whenever a tracked task completes (success or failure).
    //
    completionCallbacks: std.ArrayList(ICompletionCallbackRegistration),

    //
    // Callbacks invoked when a tracked task emits an event of a specific type.
    //
    eventCallbacks: std.ArrayList(IEventCallbackRegistration),

    //
    // Callbacks invoked for every event emitted by a tracked task (regardless of type).
    //
    anyEventCallbacks: std.ArrayList(IAnyEventCallbackRegistration),

    //
    // Count of tasks that have been added but not yet completed.
    //
    numTasksInFlight: i64,

    //
    // Set of task IDs owned by this queue, used to filter backend callbacks.
    //
    trackedTaskIds: std.StringHashMapUnmanaged(void),

    //
    // Callers waiting in awaitAllTasks(), resolved when numTasksInFlight reaches zero.
    //
    awaitAllResolvers: std.ArrayList(*IAwaitAllResolver),

    //
    // Callers waiting in awaitTask(taskId). A resolver receives the task's ITaskResult on normal
    // completion, or null when the queue is shut down before the task completes.
    // (The list is searched by task ID.)
    //
    awaitTaskResolvers: std.ArrayList(*IAwaitTaskResolver),

    //
    // Unsubscribe functions returned by backend subscriptions, called on shutdown.
    //
    unsubscribeFunctions: std.ArrayList(UnsubscribeFn),

    //
    // The key of the next callback registration.
    //
    nextCallbackKey: usize,

    //
    // Whether shutdown has run, so that deinit does not cancel the tasks of the source a second time.
    //
    isShutDown: bool,

    //
    // Creates a queue for the tasks of `source` on the backend the calling thread registered with setQueueBackend, with the calling
    // thread's allocator, which every other function is given too. Free it with deinit.
    //
    pub fn init(allocator: std.mem.Allocator, uuidGenerator: IUuidGenerator, source: []const u8) !*TaskQueue {
        const backend = try getQueueBackend();
        const self = try allocator.create(TaskQueue);
        errdefer allocator.destroy(self);
        self.* = .{
            .uuidGenerator = uuidGenerator,
            .source = try allocator.dupe(u8, source),
            .backend = backend,
            .completionCallbacks = .empty,
            .eventCallbacks = .empty,
            .anyEventCallbacks = .empty,
            .numTasksInFlight = 0,
            .trackedTaskIds = .empty,
            .awaitAllResolvers = .empty,
            .awaitTaskResolvers = .empty,
            .unsubscribeFunctions = .empty,
            .nextCallbackKey = 0,
            .isShutDown = false,
        };
        errdefer self.release(allocator);
        try self.unsubscribeFunctions.append(allocator, try self.backend.onTaskAdded(allocator, self.source, .{
            .context = self,
            .function = onBackendTaskAdded,
        }));
        try self.unsubscribeFunctions.append(allocator, try self.backend.onTaskComplete(allocator, .{
            .context = self,
            .function = onBackendTaskComplete,
        }));
        try self.unsubscribeFunctions.append(allocator, try self.backend.onAnyTaskEvent(allocator, .{
            .context = self,
            .function = onBackendAnyTaskEvent,
        }));
        try self.unsubscribeFunctions.append(allocator, try self.backend.onTasksCancelled(allocator, self.source, .{
            .context = self,
            .function = onBackendTasksCancelled,
        }));
        return self;
    }

    //
    // Shuts the queue down (if it is not already) and frees it.
    //
    pub fn deinit(self: *TaskQueue, io: std.Io, allocator: std.mem.Allocator, log: ILog) void {
        if (!self.isShutDown) {
            self.shutdown(io, allocator, log);
        }
        self.release(allocator);
        allocator.destroy(self);
    }

    //
    // Frees what the queue holds, but not the queue.
    //
    fn release(self: *TaskQueue, allocator: std.mem.Allocator) void {
        for (self.unsubscribeFunctions.items) |unsubscribe| {
            unsubscribe.call(allocator);
        }
        self.unsubscribeFunctions.deinit(allocator);
        var tracked_iterator = self.trackedTaskIds.keyIterator();
        while (tracked_iterator.next()) |key| {
            allocator.free(key.*);
        }
        for (self.eventCallbacks.items) |registration| {
            allocator.free(registration.entry.eventType);
        }
        self.completionCallbacks.deinit(allocator);
        self.eventCallbacks.deinit(allocator);
        self.anyEventCallbacks.deinit(allocator);
        self.trackedTaskIds.deinit(allocator);
        self.awaitAllResolvers.deinit(allocator);
        self.awaitTaskResolvers.deinit(allocator);
        allocator.free(self.source);
    }

    //
    // Backend callback: a task with this queue's source was added.
    //
    fn onBackendTaskAdded(context: ?*anyopaque, allocator: std.mem.Allocator, log: ILog, taskId: []const u8) void {
        const self: *TaskQueue = @ptrCast(@alignCast(context.?));
        const entry = self.trackedTaskIds.getOrPut(allocator, taskId) catch |err| {
            log.exception("Failed to track task", err);
            return;
        };
        if (!entry.found_existing) {
            entry.key_ptr.* = allocator.dupe(u8, taskId) catch |err| {
                _ = self.trackedTaskIds.remove(taskId);
                log.exception("Failed to track task", err);
                return;
            };
        }
        self.numTasksInFlight += 1;
    }

    //
    // Backend callback: a task completed. The callbacks of a tracked task run now.
    //
    fn onBackendTaskComplete(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog, result: ITaskResult) anyerror!void {
        const self: *TaskQueue = @ptrCast(@alignCast(context.?));
        if (!self.trackedTaskIds.contains(result.taskId)) {
            return;
        }
        try self.notifyCompletionCallbacks(io, allocator, timers, log, result);
    }

    //
    // Backend callback: a task sent an event. The callbacks of a tracked task run now.
    //
    fn onBackendAnyTaskEvent(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog, sent: ITaskEventData) anyerror!void {
        const self: *TaskQueue = @ptrCast(@alignCast(context.?));
        if (!self.trackedTaskIds.contains(sent.taskId)) {
            return;
        }
        try self.notifyEventCallbacks(io, allocator, timers, log, sent.taskId, sent.event);
    }

    //
    // Backend callback: the tasks of this queue's source were cancelled.
    //
    fn onBackendTasksCancelled(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        _ = io;
        _ = allocator;
        const self: *TaskQueue = @ptrCast(@alignCast(context.?));
        self.resolveAllWaiters();
    }

    //
    // Resolves all pending awaitAllTasks() and awaitTask() callers immediately.
    //
    fn resolveAllWaiters(self: *TaskQueue) void {
        for (self.awaitAllResolvers.items) |resolver| {
            resolver.resolved = true;
        }
        self.awaitAllResolvers.clearRetainingCapacity();

        for (self.awaitTaskResolvers.items) |resolver| {
            resolver.result = null;
            resolver.resolved = true;
        }
        self.awaitTaskResolvers.clearRetainingCapacity();
    }

    //
    // Adds a task to the queue to be executed. Returns the task ID (UUID), allocated with the allocator when the queue made it.
    // If taskId is provided (and not empty), it will be used instead of generating a new one.
    //
    pub fn addTask(self: *TaskQueue, io: std.Io, allocator: std.mem.Allocator, log: ILog, @"type": []const u8, data: std.json.Value, taskId: ?[]const u8, priority: ?TaskPriority) ![]const u8 {
        const id = if (taskId != null and taskId.?.len > 0) taskId.? else try self.uuidGenerator.generate(allocator, io);
        const backend_id = try self.backend.addTask(allocator, io, log, @"type", data, self.source, id, priority);
        allocator.free(backend_id);
        return id;
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    // Returns an unsubscribe function to remove the callback.
    //
    pub fn onTaskComplete(self: *TaskQueue, allocator: std.mem.Allocator, callback: TaskCompletionCallback) !UnsubscribeFn {
        const key = self.nextCallbackKey;
        self.nextCallbackKey += 1;
        try self.completionCallbacks.append(allocator, .{ .key = key, .callback = callback });
        return .{ .context = self, .key = key, .function = unsubscribeCompletionCallback };
    }

    //
    // Removes a completion callback (the function returned by onTaskComplete).
    //
    fn unsubscribeCompletionCallback(context: ?*anyopaque, allocator: std.mem.Allocator, key: usize) void {
        _ = allocator;
        const self: *TaskQueue = @ptrCast(@alignCast(context.?));
        for (self.completionCallbacks.items, 0..) |registration, index| {
            if (registration.key == key) {
                _ = self.completionCallbacks.orderedRemove(index);
                return;
            }
        }
    }

    //
    // Registers a callback that will be called when a task sends events to the client.
    // Only events with the specified eventType will be passed to the callback.
    // Returns an unsubscribe function to remove the callback.
    //
    pub fn onTaskEvent(self: *TaskQueue, allocator: std.mem.Allocator, eventType: []const u8, callback: TaskEventCallback) !UnsubscribeFn {
        const owned_event_type = try allocator.dupe(u8, eventType);
        errdefer allocator.free(owned_event_type);
        const key = self.nextCallbackKey;
        self.nextCallbackKey += 1;
        try self.eventCallbacks.append(allocator, .{
            .key = key,
            .entry = .{ .eventType = owned_event_type, .callback = callback },
        });
        return .{ .context = self, .key = key, .function = unsubscribeEventCallback };
    }

    //
    // Removes an event callback (the function returned by onTaskEvent).
    //
    fn unsubscribeEventCallback(context: ?*anyopaque, allocator: std.mem.Allocator, key: usize) void {
        const self: *TaskQueue = @ptrCast(@alignCast(context.?));
        for (self.eventCallbacks.items, 0..) |registration, index| {
            if (registration.key == key) {
                allocator.free(registration.entry.eventType);
                _ = self.eventCallbacks.orderedRemove(index);
                return;
            }
        }
    }

    //
    // Registers a callback that will be called for every event sent by any tracked task,
    // regardless of the event type.
    // Returns an unsubscribe function to remove the callback.
    //
    pub fn onAnyTaskEvent(self: *TaskQueue, allocator: std.mem.Allocator, callback: TaskEventCallback) !UnsubscribeFn {
        const key = self.nextCallbackKey;
        self.nextCallbackKey += 1;
        try self.anyEventCallbacks.append(allocator, .{
            .key = key,
            .callback = callback,
        });
        return .{
            .context = self,
            .key = key,
            .function = unsubscribeAnyEventCallback,
        };
    }

    //
    // Removes a callback registered with onAnyTaskEvent (the function onAnyTaskEvent returned).
    //
    fn unsubscribeAnyEventCallback(context: ?*anyopaque, allocator: std.mem.Allocator, key: usize) void {
        _ = allocator;
        const self: *TaskQueue = @ptrCast(@alignCast(context.?));
        for (self.anyEventCallbacks.items, 0..) |registration, index| {
            if (registration.key == key) {
                _ = self.anyEventCallbacks.orderedRemove(index);
                return;
            }
        }
    }

    //
    // Returns when all currently in-flight tasks have completed, reading the thread's messages, which runs the queue's
    // callbacks for the completions and events that arrive meanwhile, and the thread's timers that come due.
    // Returns immediately if no tasks are in flight.
    //
    pub fn awaitAllTasks(self: *TaskQueue, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog) !void {
        if (self.numTasksInFlight <= 0) {
            return;
        }
        var resolver: IAwaitAllResolver = .{ .resolved = false };
        try self.awaitAllResolvers.append(allocator, &resolver);
        self.waitUntilResolved(io, allocator, timers, log, &resolver.resolved);
    }

    //
    // Returns the task's result when the task with the given ID completes (allocated with the
    // allocator), reading the thread's messages meanwhile.
    // Returns null when the task ID is not tracked by this queue,
    // or when the queue is shut down / its tasks are cancelled before completion.
    //
    pub fn awaitTask(self: *TaskQueue, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog, taskId: []const u8) !?ITaskResult {
        if (!self.trackedTaskIds.contains(taskId)) {
            return null;
        }
        var resolver: IAwaitTaskResolver = .{
            .taskId = taskId,
            .result = null,
            .copyError = null,
            .resolved = false,
        };
        try self.awaitTaskResolvers.append(allocator, &resolver);
        self.waitUntilResolved(io, allocator, timers, log, &resolver.resolved);
        if (resolver.copyError) |err| {
            return err;
        }
        return resolver.result;
    }

    //
    // Reads the thread's messages through the backend until `resolved` is set.
    //
    fn waitUntilResolved(self: *TaskQueue, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog, resolved: *bool) void {
        while (!resolved.*) {
            self.backend.waitForMessage(io, allocator, timers, log);
        }
    }

    //
    // Invokes all registered completion callbacks with the task result, then resolves the callers waiting for it.
    // Callback errors are caught and logged to prevent breaking the queue.
    //
    fn notifyCompletionCallbacks(self: *TaskQueue, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog, result: ITaskResult) !void {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const callbacks = try scratch.allocator().dupe(ICompletionCallbackRegistration, self.completionCallbacks.items);
        if (self.trackedTaskIds.fetchRemove(result.taskId)) |removed| {
            allocator.free(removed.key);
        }
        self.numTasksInFlight -= 1;

        for (callbacks) |registration| {
            registration.callback.call(io, allocator, timers, log, result) catch |err| {
                log.exception("Error in task completion callback", err);
            };
        }

        // Resolve awaitTask waiters for this task ID.
        const resultJson = try std.json.Stringify.valueAlloc(scratch.allocator(), result, .{});
        var index: usize = 0;
        while (index < self.awaitTaskResolvers.items.len) {
            const resolver = self.awaitTaskResolvers.items[index];
            if (!std.mem.eql(u8, resolver.taskId, result.taskId)) {
                index += 1;
                continue;
            }
            if (std.json.parseFromSliceLeaky(ITaskResult, allocator, resultJson, .{ .allocate = .alloc_always })) |copied_result| {
                resolver.result = copied_result;
            }
            else |err| {
                resolver.copyError = err;
            }
            resolver.resolved = true;
            _ = self.awaitTaskResolvers.orderedRemove(index);
        }

        // Resolve awaitAll waiters if all tasks are done.
        if (self.numTasksInFlight <= 0) {
            for (self.awaitAllResolvers.items) |resolver| {
                resolver.resolved = true;
            }
            self.awaitAllResolvers.clearRetainingCapacity();
        }
    }

    //
    // Invokes all registered event callbacks with the task's event.
    // Only callbacks that match the event type will be invoked.
    // Callback errors are caught and logged to prevent breaking the queue.
    //
    fn notifyEventCallbacks(self: *TaskQueue, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog, taskId: []const u8, event: std.json.Value) !void {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const eventType = types.eventTypeOf(event);

        var callbacks: std.ArrayList(TaskEventCallback) = .empty;
        for (self.eventCallbacks.items) |registration| {
            if (eventType == null or !std.mem.eql(u8, eventType.?, registration.entry.eventType)) {
                continue;
            }
            try callbacks.append(scratch.allocator(), registration.entry.callback);
        }
        const anyCallbacks = try scratch.allocator().dupe(IAnyEventCallbackRegistration, self.anyEventCallbacks.items);

        for (callbacks.items) |callback| {
            callback.call(io, allocator, timers, log, .{ .taskId = taskId, .event = event }) catch |err| {
                log.exception("Error in task event callback", err);
            };
        }

        for (anyCallbacks) |registration| {
            registration.callback.call(io, allocator, timers, log, .{
                .taskId = taskId,
                .event = event,
            }) catch |err| {
                log.exception("Error in any task event callback", err);
            };
        }
    }

    //
    // Cancels all in-flight tasks belonging to this queue and cleans up subscriptions.
    // Any callers waiting in awaitAllTasks() or awaitTask() are resolved immediately.
    //
    pub fn shutdown(self: *TaskQueue, io: std.Io, allocator: std.mem.Allocator, log: ILog) void {
        self.isShutDown = true;
        self.backend.cancelTasks(io, allocator, log, self.source);

        const unsubscribeFunctions = self.unsubscribeFunctions;
        self.unsubscribeFunctions = .empty;
        for (unsubscribeFunctions.items) |unsubscribe| {
            unsubscribe.call(allocator);
        }
        var owned_unsubscribe_functions = unsubscribeFunctions;
        owned_unsubscribe_functions.deinit(allocator);

        var tracked_iterator = self.trackedTaskIds.keyIterator();
        while (tracked_iterator.next()) |key| {
            allocator.free(key.*);
        }
        self.trackedTaskIds.clearRetainingCapacity();
        self.resolveAllWaiters();
        for (self.eventCallbacks.items) |registration| {
            allocator.free(registration.entry.eventType);
        }
        self.eventCallbacks.clearRetainingCapacity();
        self.anyEventCallbacks.clearRetainingCapacity();
        self.completionCallbacks.clearRetainingCapacity();
    }
};
