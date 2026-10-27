const std = @import("std");
const task_queue_zig = @import("ziggy").task_queue;
const utils = @import("ziggy").task_queue.utils;
const TaskContext = task_queue_zig.task_context.TaskContext;
const SendEventFn = task_queue_zig.task_context.SendEventFn;

//
// Records the events passed to the send-event function.
//
const EventRecorder = struct {
    // Number of calls.
    calls: usize,

    // The type field of the last event.
    lastType: []const u8,

    // The value field of the last event.
    lastValue: i64,

    //
    // Records an event.
    //
    fn record(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, event: std.json.Value) void {
        _ = io;
        _ = allocator;
        const self: *EventRecorder = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.lastType = event.object.get("type").?.string;
        self.lastValue = event.object.get("value").?.integer;
    }

    //
    // Gets the send-event function that records into this recorder.
    //
    fn sendEventFn(self: *EventRecorder) SendEventFn {
        return .{ .context = self, .function = record };
    }
};

test "isCancelled returns false initially" {
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.test_timestamp_provider.TestTimestampProvider = .{};
    var recorder: EventRecorder = .{ .calls = 0, .lastType = "", .lastValue = 0 };
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "session-1", "task-1", recorder.sendEventFn(), 10);

    try std.testing.expect(!context.isCancelled());
}

test "cancel causes isCancelled to return true" {
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.test_timestamp_provider.TestTimestampProvider = .{};
    var recorder: EventRecorder = .{ .calls = 0, .lastType = "", .lastValue = 0 };
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "session-1", "task-1", recorder.sendEventFn(), 10);

    context.cancel();

    try std.testing.expect(context.isCancelled());
    try std.testing.expect(context.taskContext().isCancelled(std.testing.io, std.testing.allocator));
}

test "sendEvent invokes the injected sendEventFn with the correct argument" {
    const console_log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.test_timestamp_provider.TestTimestampProvider = .{};
    var recorder: EventRecorder = .{ .calls = 0, .lastType = "", .lastValue = 0 };
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "session-1", "task-1", recorder.sendEventFn(), 10);

    const msg = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"type\":\"progress\",\"value\":42}", .{});
    context.sendEvent(std.testing.io, arena.allocator(), msg);

    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqualStrings("progress", recorder.lastType);
    try std.testing.expectEqual(@as(i64, 42), recorder.lastValue);

    // Through the ITaskContext interface too.
    context.taskContext().sendEvent(std.testing.io, arena.allocator(), console_log, msg);
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
}

test "everything the task needs is exposed as provided" {
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.test_timestamp_provider.TestTimestampProvider = .{};
    var recorder: EventRecorder = .{ .calls = 0, .lastType = "", .lastValue = 0 };
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "my-session", "my-task", recorder.sendEventFn(), 7);

    try std.testing.expect(context.uuidGenerator.ptr == @as(*anyopaque, &uuid_generator));
    try std.testing.expect(context.timestampProvider.ptr == @as(*anyopaque, &timestamp_provider));
    try std.testing.expectEqualStrings("my-session", context.sessionId);
    try std.testing.expectEqualStrings("my-task", context.taskId);
    const interface = context.taskContext();
    try std.testing.expectEqualStrings("my-session", interface.sessionId);
    try std.testing.expectEqualStrings("my-task", interface.taskId);

    // How many child tasks a task may run at once comes from the platform that built the
    // context, because only it knows what the machine can take.
    try std.testing.expectEqual(@as(u32, 7), context.maxConcurrentChildTasks);
    try std.testing.expectEqual(@as(u32, 7), interface.maxConcurrentChildTasks);
}
