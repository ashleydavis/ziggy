const std = @import("std");
const task_queue_zig = @import("ziggy").task_queue;
const utils = @import("ziggy").task_queue.utils;

const types = task_queue_zig.types;
const WorkerQueueBackend = task_queue_zig.worker_queue_backend.WorkerQueueBackend;
const Timers = @import("ziggy").timers.Timers;
const TimerList = @import("ziggy").timers.TimerList;

//
// What the backend of a test sends and how many times it waited for a message.
//
const Sent = struct {
    // The JSON text of every message posted, in order.
    messages: std.ArrayList([]u8) = .empty,
    // The number of times the backend waited for a message.
    waits: u32 = 0,
    // What the callbacks were given, one line each.
    lines: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Sent) void {
        for (self.messages.items) |text| {
            std.testing.allocator.free(text);
        }
        self.messages.deinit(std.testing.allocator);
        for (self.lines.items) |text| {
            std.testing.allocator.free(text);
        }
        self.lines.deinit(std.testing.allocator);
    }

    fn post(context: ?*anyopaque, io: std.Io, text: []const u8) anyerror!void {
        _ = io;
        const self: *Sent = @ptrCast(@alignCast(context.?));
        try self.messages.append(std.testing.allocator, try std.testing.allocator.dupe(u8, text));
    }

    fn wait(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers) void {
        _ = io;
        _ = allocator;
        _ = timers;
        const self: *Sent = @ptrCast(@alignCast(context.?));
        self.waits += 1;
    }

    fn line(self: *Sent, comptime format: []const u8, arguments: anytype) void {
        self.lines.append(std.testing.allocator, std.fmt.allocPrint(std.testing.allocator, format, arguments) catch @panic("out of memory")) catch @panic("out of memory");
    }

    fn onAdded(context: ?*anyopaque, allocator: std.mem.Allocator, task_id: []const u8) void {
        _ = allocator;
        const self: *Sent = @ptrCast(@alignCast(context.?));
        self.line("added|{s}", .{task_id});
    }

    fn onComplete(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, result: types.ITaskResult) anyerror!void {
        _ = io;
        _ = allocator;
        const self: *Sent = @ptrCast(@alignCast(context.?));
        self.line("complete|{s}|{s}", .{ result.taskId, result.status.toString() });
    }

    fn onCancelled(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        _ = io;
        _ = allocator;
        const self: *Sent = @ptrCast(@alignCast(context.?));
        self.line("cancelled", .{});
    }

    fn onTyped(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, data: types.ITaskEventData) anyerror!void {
        _ = io;
        _ = allocator;
        const self: *Sent = @ptrCast(@alignCast(context.?));
        self.line("typed|{s}", .{data.taskId});
    }

    fn onAny(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, _: Timers, data: types.ITaskEventData) anyerror!void {
        _ = io;
        _ = allocator;
        const self: *Sent = @ptrCast(@alignCast(context.?));
        self.line("any|{s}", .{data.taskId});
    }
};

//
// Makes a backend whose messages and waits the record takes.
//
fn makeBackend(sent: *Sent, uuid_generator: *utils.random_uuid_generator.RandomUuidGenerator) WorkerQueueBackend {
    return WorkerQueueBackend.init(.{
        .context = sent,
        .function = Sent.post,
    }, .{
        .context = sent,
        .function = Sent.wait,
    }, uuid_generator.uuidGenerator());
}

test "addTask sends the main thread a queue-task message, with the priority requested, and fires the callbacks of its source" {
    var sent: Sent = .{};
    defer sent.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var backend = makeBackend(&sent, &uuid_generator);
    defer backend.deinit(std.testing.allocator);
    const unsubscribe = try backend.onTaskAdded(std.testing.allocator, "db", .{
        .context = &sent,
        .function = Sent.onAdded,
    });
    const id = try backend.addTask(std.testing.allocator, std.testing.io, "hash", .{ .integer = 3 }, "db", "child-1", .Interactive);
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("child-1", id);
    try std.testing.expectEqualStrings("{\"type\":\"queue-task\",\"taskId\":\"child-1\",\"taskType\":\"hash\",\"data\":3,\"source\":\"db\",\"priority\":\"interactive\"}", sent.messages.items[0]);
    try std.testing.expectEqualStrings("added|child-1", sent.lines.items[0]);
    unsubscribe.call(std.testing.allocator);
    const other = try backend.addTask(std.testing.allocator, std.testing.io, "hash", .null, "db", null, null);
    defer std.testing.allocator.free(other);
    // An id is made for a task given none, and a priority not requested is left out for the main thread to choose.
    try std.testing.expectEqual(@as(usize, 36), other.len);
    try std.testing.expect(std.mem.indexOf(u8, sent.messages.items[1], "priority") == null);
    try std.testing.expectEqual(@as(usize, 1), sent.lines.items.len);
}

test "notifyTaskCompleted fires the completion callbacks, and cancelTasks the callbacks of the source cancelled" {
    var sent: Sent = .{};
    defer sent.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var backend = makeBackend(&sent, &uuid_generator);
    var timer_list = TimerList.init();
    defer backend.deinit(std.testing.allocator);
    _ = try backend.onTaskComplete(std.testing.allocator, .{
        .context = &sent,
        .function = Sent.onComplete,
    });
    _ = try backend.onTasksCancelled(std.testing.allocator, "db", .{
        .context = &sent,
        .function = Sent.onCancelled,
    });
    try backend.notifyTaskCompleted(std.testing.io, std.testing.allocator, timer_list.interface(), .{
        .taskId = "c1",
        .status = .Succeeded,
        .type = "hash",
        .inputs = .null,
    });
    backend.cancelTasks(std.testing.io, std.testing.allocator, "other");
    backend.cancelTasks(std.testing.io, std.testing.allocator, "db");
    try std.testing.expectEqual(@as(usize, 2), sent.lines.items.len);
    try std.testing.expectEqualStrings("complete|c1|succeeded", sent.lines.items[0]);
    try std.testing.expectEqualStrings("cancelled", sent.lines.items[1]);
}

test "notifyTaskMessage fires the callbacks for the event's type and those for every event" {
    var sent: Sent = .{};
    defer sent.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var backend = makeBackend(&sent, &uuid_generator);
    var timer_list = TimerList.init();
    defer backend.deinit(std.testing.allocator);
    _ = try backend.onTaskEvent(std.testing.allocator, "progress", .{
        .context = &sent,
        .function = Sent.onTyped,
    });
    _ = try backend.onAnyTaskEvent(std.testing.allocator, .{
        .context = &sent,
        .function = Sent.onAny,
    });
    var event: std.json.ObjectMap = .empty;
    defer event.deinit(std.testing.allocator);
    try event.put(std.testing.allocator, "type", .{ .string = "progress" });
    try backend.notifyTaskMessage(std.testing.io, std.testing.allocator, timer_list.interface(), "c1", .{ .object = event });
    try backend.notifyTaskMessage(std.testing.io, std.testing.allocator, timer_list.interface(), "c2", .{ .string = "untyped" });
    try std.testing.expectEqual(@as(usize, 3), sent.lines.items.len);
    try std.testing.expectEqualStrings("typed|c1", sent.lines.items[0]);
    try std.testing.expectEqualStrings("any|c1", sent.lines.items[1]);
    try std.testing.expectEqualStrings("any|c2", sent.lines.items[2]);
}

test "waitForMessage has the worker read its next message, and shutdown does nothing" {
    var sent: Sent = .{};
    defer sent.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var backend = makeBackend(&sent, &uuid_generator);
    defer backend.deinit(std.testing.allocator);
    const interface = backend.queueBackend();
    var timer_list = TimerList.init();
    interface.waitForMessage(std.testing.io, std.testing.allocator, timer_list.interface());
    interface.waitForMessage(std.testing.io, std.testing.allocator, timer_list.interface());
    interface.shutdown(std.testing.io, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), sent.waits);
    try std.testing.expectEqual(@as(usize, 0), sent.messages.items.len);
}
