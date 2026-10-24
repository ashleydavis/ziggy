const std = @import("std");
const task_queue_zig = @import("ziggy").task_queue;
const utils = @import("ziggy").task_queue.utils;
const queue_backend = task_queue_zig.queue_backend;
const types = task_queue_zig.types;
const IQueueBackend = queue_backend.IQueueBackend;
const setQueueBackend = queue_backend.setQueueBackend;
const getQueueBackend = queue_backend.getQueueBackend;
const errors = utils.errors;
const ziggy = @import("ziggy");
const Timers = ziggy.timers.Timers;
const TimerList = ziggy.timers.TimerList;
const MessageQueue = ziggy.core.MessageQueue;

//
// Minimal no-op backend for testing the singleton helpers.
//
const NoOpBackend = struct {
    // The number of calls made to the backend's functions.
    calls: u32,

    //
    // Gets the IQueueBackend interface for this backend.
    //
    fn queueBackend(self: *NoOpBackend) IQueueBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // Counts a call to one of the backend's functions.
    //
    fn countCall(ptr: *anyopaque) void {
        const self: *NoOpBackend = @ptrCast(@alignCast(ptr));
        self.calls += 1;
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
    // Returns "task-id".
    //
    fn addTask(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?types.TaskPriority) anyerror![]const u8 {
        countCall(ptr);
        _ = allocator;
        _ = io;
        _ = @"type";
        _ = data;
        _ = source;
        _ = taskId;
        _ = priority;
        return "task-id";
    }

    //
    // Does nothing.
    //
    fn noUnsubscribe(context: ?*anyopaque, allocator: std.mem.Allocator, key: usize) void {
        _ = allocator;
        _ = context;
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
        _ = allocator;
        countCall(ptr);
        _ = source;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTaskComplete(ptr: *anyopaque, allocator: std.mem.Allocator, callback: types.WorkerTaskCompletionCallback) anyerror!types.UnsubscribeFn {
        _ = allocator;
        countCall(ptr);
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTaskEvent(ptr: *anyopaque, allocator: std.mem.Allocator, eventType: []const u8, callback: types.TaskEventCallback) anyerror!types.UnsubscribeFn {
        _ = allocator;
        countCall(ptr);
        _ = eventType;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onAnyTaskEvent(ptr: *anyopaque, allocator: std.mem.Allocator, callback: types.TaskEventCallback) anyerror!types.UnsubscribeFn {
        _ = allocator;
        countCall(ptr);
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Does nothing.
    //
    fn cancelTasks(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, source: []const u8) void {
        _ = io;
        _ = allocator;
        countCall(ptr);
        _ = source;
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTasksCancelled(ptr: *anyopaque, allocator: std.mem.Allocator, source: []const u8, callback: types.TasksCancelledCallback) anyerror!types.UnsubscribeFn {
        _ = allocator;
        countCall(ptr);
        _ = source;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Does nothing.
    //
    fn shutdown(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        _ = io;
        _ = allocator;
        countCall(ptr);
    }

    //
    // Counts the call.
    //
    fn waitForMessage(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers) void {
        _ = io;
        _ = allocator;
        _ = timers;
        countCall(ptr);
    }
};

test "queue-backend singleton: getQueueBackend throws before setQueueBackend is called" {
    // Force the singleton to null so getQueueBackend throws.
    setQueueBackend(null);
    try std.testing.expectError(error.Thrown, getQueueBackend());
    try std.testing.expectEqualStrings("Queue backend not initialised \u{2014} call setQueueBackend() at process startup.", errors.lastErrorMessage());
}

test "queue-backend singleton: getQueueBackend returns the backend set by setQueueBackend" {
    var backend: NoOpBackend = .{ .calls = 0 };
    setQueueBackend(backend.queueBackend());
    defer setQueueBackend(null);
    try std.testing.expect((try getQueueBackend()).ptr == @as(*anyopaque, &backend));
}

test "queue-backend singleton: calling setQueueBackend a second time replaces the previously registered backend" {
    var backend1: NoOpBackend = .{ .calls = 0 };
    var backend2: NoOpBackend = .{ .calls = 0 };
    setQueueBackend(backend1.queueBackend());
    setQueueBackend(backend2.queueBackend());
    defer setQueueBackend(null);
    try std.testing.expect((try getQueueBackend()).ptr == @as(*anyopaque, &backend2));
    try std.testing.expect((try getQueueBackend()).ptr != @as(*anyopaque, &backend1));
}

test "IQueueBackend forwards every method to the implementation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var timer_list = TimerList.init();
    var backend: NoOpBackend = .{ .calls = 0 };
    const interface = backend.queueBackend();
    try std.testing.expectEqualStrings("task-id", try interface.addTask(allocator, io, "t", .null, "s", null, null));
    const unsubscribe = try interface.onTaskComplete(allocator, .{ .context = null, .function = undefined });
    unsubscribe.call(allocator);
    interface.cancelTasks(io, allocator, "s");
    interface.shutdown(io, allocator);
    interface.waitForMessage(io, allocator, timer_list.interface());
    try std.testing.expectEqual(@as(u32, 5), backend.calls);
}

//
// Tells the test's thread, on the queue given, whether the calling thread has a backend, which no test set on this thread.
//
fn readBackendOnThread(replies: *MessageQueue) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const found = if (getQueueBackend()) |_| "\"found\"" else |_| "null";
    replies.post(threaded.io(), 0, found) catch @panic("out of memory replying to the test");
}

test "queue-backend: each thread has its own backend, and one set on one thread is not seen on another" {
    const io = std.testing.io;
    var backend: NoOpBackend = .{ .calls = 0 };
    setQueueBackend(backend.queueBackend());
    defer setQueueBackend(null);
    var replies = MessageQueue.init();
    defer replies.deinit();
    const reader = try std.Thread.spawn(.{}, readBackendOnThread, .{&replies});
    reader.join();
    const reply = replies.take(io, std.testing.allocator, .none).?;
    defer std.testing.allocator.free(reply.text);
    try std.testing.expectEqualStrings("null", reply.text);
    try std.testing.expect((try getQueueBackend()).ptr == @as(*anyopaque, &backend));
}

test "IQueueBackend forwards the subscriptions to the implementation" {
    const allocator = std.testing.allocator;
    var backend: NoOpBackend = .{ .calls = 0 };
    const interface = backend.queueBackend();
    (try interface.onTaskAdded(allocator, "s", .{ .context = null, .function = undefined })).call(allocator);
    (try interface.onTaskEvent(allocator, "progress", .{ .context = null, .function = undefined })).call(allocator);
    (try interface.onAnyTaskEvent(allocator, .{ .context = null, .function = undefined })).call(allocator);
    (try interface.onTasksCancelled(allocator, "s", .{ .context = null, .function = undefined })).call(allocator);
    try std.testing.expectEqual(@as(u32, 4), backend.calls);
}
