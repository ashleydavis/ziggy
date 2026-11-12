//
// The task types the core's tests register: small task handlers that finish, fail, sleep, spin, start children or show a dialog, each
// named for what a test needs a task to do.
//

const std = @import("std");
const ziggy = @import("ziggy");

const task_runner = ziggy.task_runner;
const TaskServices = task_runner.TaskServices;
const TaskContext = task_runner.TaskContext;
const Timers = ziggy.timers.Timers;
const Raw = ziggy.json.Raw;

//
// Sleeps for a task, returning error.Cancelled early when the task is cancelled.
//
fn sleepOrCancel(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, milliseconds: i64) !void {
    var remaining = milliseconds;
    while (remaining > 0) : (remaining -= 1) {
        try services.checkCancelled(io, allocator);
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try services.checkCancelled(io, allocator);
}

fn quickTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) ![]const u8 {
    _ = timers;
    _ = context;
    _ = payload;
    try services.sendEvent(io, allocator, .{ .text = "hello" });
    return "done";
}

fn spinTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !void {
    _ = timers;
    _ = context;
    _ = payload;
    var step: u32 = 0;
    while (true) : (step += 1) {
        try services.checkCancelled(io, allocator);
        try services.sendEvent(io, allocator, .{ .step = step });
        try io.sleep(.fromMilliseconds(2), .awake);
    }
}

fn failTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !void {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = payload;
    return error.TestFailure;
}

fn sleepTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !void {
    _ = timers;
    _ = context;
    const milliseconds = ziggy.json.getInteger(payload, "ms") orelse 0;
    const name = ziggy.json.getString(payload, "name") orelse "sleep";
    try services.sendEvent(io, allocator, .{ .start = name });
    try sleepOrCancel(services, io, allocator, milliseconds);
    try services.sendEvent(io, allocator, .{ .end = name });
}

fn parentTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !void {
    _ = context;
    const children = ziggy.json.getInteger(payload, "children") orelse 0;
    const child_ms = ziggy.json.getInteger(payload, "childMs") orelse 5;
    const parent_name = ziggy.json.getString(payload, "name") orelse "parent";
    var index: i64 = 0;
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(allocator);
    while (index < children) : (index += 1) {
        try ids.append(allocator, try services.queueChild(io, allocator, timers, "child", .{ .name = parent_name, .ms = child_ms }, null));
    }
    for (ids.items) |id| {
        _ = try services.awaitTask(io, allocator, timers, id);
    }
    try services.sendEvent(io, allocator, .{ .allChildrenDone = parent_name });
}

fn awaitOneTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !Raw {
    _ = context;
    _ = payload;
    const first = try services.queueChild(io, allocator, timers, "child-result", .{}, null);
    const second = try services.queueChild(io, allocator, timers, "fail", .{}, null);
    const first_completion = try services.awaitTask(io, allocator, timers, first);
    const second_completion = try services.awaitTask(io, allocator, timers, second);
    return .{
        .text = try ziggy.json.stringify(allocator, .{
            .first = @tagName(first_completion.status),
            .firstResult = Raw{ .text = first_completion.result_json orelse "null" },
            .second = @tagName(second_completion.status),
            .secondError = second_completion.error_message orelse "",
        }),
    };
}

fn runChildrenInTurnTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !Raw {
    _ = context;
    _ = payload;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const child_allocator = arena_state.allocator();
    const first = try services.runChild(io, allocator, timers, child_allocator, "child-result", .{}, null);
    const second = try services.runChild(io, allocator, timers, child_allocator, "fail", .{}, null);
    const third = try services.runChild(io, allocator, timers, child_allocator, "child-result", .{}, null);
    return .{
        .text = try ziggy.json.stringify(allocator, .{
            .first = @tagName(first.status),
            .firstResult = Raw{ .text = first.result_json orelse "null" },
            .second = @tagName(second.status),
            .secondError = second.error_message orelse "",
            .third = @tagName(third.status),
            .thirdResult = Raw{ .text = third.result_json orelse "null" },
        }),
    };
}

fn childResultTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) ![]const u8 {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = payload;
    return "child result";
}

fn childTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !void {
    _ = timers;
    _ = context;
    const milliseconds = ziggy.json.getInteger(payload, "ms") orelse 0;
    const name = ziggy.json.getString(payload, "name") orelse "child";
    try services.sendEvent(io, allocator, .{ .childStart = name });
    try sleepOrCancel(services, io, allocator, milliseconds);
    try services.sendEvent(io, allocator, .{ .childEnd = name });
}

fn blockedParentTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !void {
    _ = context;
    _ = payload;
    const first = try services.queueChild(io, allocator, timers, "child", .{ .name = "blocked", .ms = 100000 }, null);
    const second = try services.queueChild(io, allocator, timers, "child", .{ .name = "blocked", .ms = 100000 }, null);
    _ = try services.awaitTask(io, allocator, timers, first);
    _ = try services.awaitTask(io, allocator, timers, second);
    try services.checkCancelled(io, allocator);
}

fn flooderTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !void {
    _ = timers;
    _ = context;
    const count = ziggy.json.getInteger(payload, "count") orelse 0;
    var index: i64 = 0;
    while (index < count) : (index += 1) {
        try services.sendEvent(io, allocator, .{ .seq = index });
    }
}

fn pickOpenTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !Raw {
    _ = context;
    const title: ?[]const u8 = if (payload == .string) payload.string else null;
    return .{
        .text = try services.pickPaths(io, allocator, timers, .open_files, title, null),
    };
}

fn pickSaveTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !Raw {
    _ = context;
    const initial_name: ?[]const u8 = if (payload == .string) payload.string else null;
    return .{
        .text = try services.pickPaths(io, allocator, timers, .save_file, null, initial_name),
    };
}

//
// The app's config and state paths a task is given, so a test can see them in its outputs.
//
const TaskPaths = struct {
    // The path of the app's config file.
    configPath: []const u8,
    // The path of the app's state file.
    statePath: []const u8,
};

fn pathsTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !TaskPaths {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = payload;
    return .{ .configPath = context.config_path, .statePath = context.state_path };
}

//
// The app's config and state paths, read from the context of a task written against the task queue package.
//
fn pathsQueueTask(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: ziggy.log.ILog, payload: std.json.Value, context: ziggy.task_queue.types.ITaskContext) anyerror!std.json.Value {
    _ = io;
    _ = timers;
    _ = log;
    _ = payload;
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "configPath", .{ .string = try allocator.dupe(u8, context.configPath) });
    try object.put(allocator, "statePath", .{ .string = try allocator.dupe(u8, context.statePath) });
    return .{ .object = object };
}

//
// The task handlers the tests register.
//
pub const task_handlers = [_]task_runner.TaskHandlerEntry{
    .{ .name = "quick", .handler = task_runner.wrapTask("quick", quickTask) },
    .{ .name = "paths", .handler = task_runner.wrapTask("paths", pathsTask) },
    .{ .name = "paths-queue", .handler = task_runner.fromQueueHandler(pathsQueueTask) },
    .{ .name = "spin", .handler = task_runner.wrapTask("spin", spinTask) },
    .{ .name = "fail", .handler = task_runner.wrapTask("fail", failTask) },
    .{ .name = "sleep", .handler = task_runner.wrapTask("sleep", sleepTask) },
    .{ .name = "parent", .handler = task_runner.wrapTask("parent", parentTask) },
    .{ .name = "child", .handler = task_runner.wrapTask("child", childTask) },
    .{ .name = "child-result", .handler = task_runner.wrapTask("child-result", childResultTask) },
    .{ .name = "await-one", .handler = task_runner.wrapTask("await-one", awaitOneTask) },
    .{ .name = "run-children-in-turn", .handler = task_runner.wrapTask("run-children-in-turn", runChildrenInTurnTask) },
    .{ .name = "blocked-parent", .handler = task_runner.wrapTask("blocked-parent", blockedParentTask) },
    .{ .name = "flooder", .handler = task_runner.wrapTask("flooder", flooderTask) },
    .{ .name = "pick-open", .handler = task_runner.wrapTask("pick-open", pickOpenTask) },
    .{ .name = "pick-save", .handler = task_runner.wrapTask("pick-save", pickSaveTask) },
    .{ .name = "keep-sleep", .handler = task_runner.wrapTask("keep-sleep", sleepTask), .kind = .keep_alive },
    .{ .name = "keep-parent", .handler = task_runner.wrapTask("keep-parent", parentTask), .kind = .keep_alive },
};
