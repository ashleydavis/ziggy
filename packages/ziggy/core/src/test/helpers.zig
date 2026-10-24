//
// What the core's tests share: the fake native app, and small task handlers.
//

const std = @import("std");
const ziggy = @import("ziggy");

const core = ziggy.core;
const task_runner = ziggy.task_runner;
const TaskServices = task_runner.TaskServices;
const TaskContext = task_runner.TaskContext;
const HandlerServices = core.HandlerServices;
const Timers = ziggy.timers.Timers;
const Raw = ziggy.json.Raw;

//
// A fake native app that records every message the core delivers.
//
pub const FakeNativeApp = ziggy.fake_native_app.FakeNativeApp;

//
// Sleeps for a task, returning error.Cancelled early when the task is cancelled.
//
pub fn sleepOrCancel(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, milliseconds: i64) !void {
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
// The task handlers the tests register.
//
pub const task_handlers = [_]task_runner.TaskHandlerEntry{
    .{ .name = "quick", .handler = task_runner.wrapTask("quick", quickTask) },
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

//
// echo: the message response is the message's data, unparsed.
//
fn echoHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, message: core.Message) !core.MessageResult {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .response = try ziggy.json.stringify(allocator, message.data),
    };
}

//
// fail: fails with error.HandlerFailed, whatever the data.
//
fn failHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: std.json.Value) !void {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = payload;
    return error.HandlerFailed;
}

//
// none: returns none, so a message with an id gets an empty successful message response.
//
fn noneHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, message: core.Message) !core.MessageResult {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = message;
    return .none;
}

//
// name: the message response is the message's name, so a test can see the name reached the handler unchanged.
//
fn nameHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, message: core.Message) !core.MessageResult {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .response = try ziggy.json.stringify(allocator, message.name),
    };
}

//
// raw: the message response is the message's name, id and data as they arrived, so a test can see the handler that takes
// ziggy.core.Message gets the message unparsed.
//
fn rawHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, message: core.Message) !core.MessageResult {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .response = try ziggy.json.stringify(allocator, .{
            .name = message.name,
            .id = message.id,
            .data = message.data,
        }),
    };
}

//
// Makes the handler of a message whose response is the result of a task of the given type, whose input is the message's data.
//
fn respondedByTask(comptime task_type: []const u8) fn (services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, message: core.Message) anyerror!core.MessageResult {
    return struct {
        fn handle(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, message: core.Message) anyerror!core.MessageResult {
            _ = services;
            _ = timers;
            _ = io;
            return .{
                .task = .{
                    .task_type = task_type,
                    .data = try ziggy.json.stringify(allocator, message.data),
                },
            };
        }
    }.handle;
}

//
// The data of a greet message.
//
pub const GreetRequest = struct {
    // Who to greet.
    name: []const u8,
    // How many times to greet them.
    times: u32 = 1,
    // A title to put before the name, or null for none.
    title: ?[]const u8 = null,
};

//
// The message response to a greet message.
//
pub const GreetResponse = struct {
    // The greeting.
    text: []const u8,
    // How many times it was given.
    times: u32,
};

//
// greet: a handler with a typed payload and result, whose response is a greeting built from the payload's fields.
//
fn greetHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: GreetRequest) !GreetResponse {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .text = try std.fmt.allocPrint(allocator, "Hello {s}{s}", .{ payload.title orelse "", payload.name }),
        .times = payload.times,
    };
}

//
// forget: a handler with a typed payload that returns nothing, so a message with an id gets a successful message response holding
// null. It sends an app event of what it was given, so a test can see it ran and with which data.
//
fn forgetHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: GreetRequest) !void {
    _ = timers;
    try services.sendEvent(io, allocator, try ziggy.json.stringify(allocator, try std.fmt.allocPrint(allocator, "forgot {s} {d}", .{ payload.name, payload.times })));
}

//
// count: a handler whose payload is not a struct.
//
fn countHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: []const u32) !usize {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    return payload.len;
}

//
// The function of the tests' `.zig` menu item "zig-item": it sends an app event, so a test can see it ran on this core.
//
fn menuItemRan(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!void {
    _ = timers;
    try services.sendEvent(io, allocator, "\"the menu item's function ran\"");
}

//
// send-app-event: sends the frontend the message's data as an app event with the handler services' sendEvent.
//
fn sendAppEventHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: std.json.Value) !void {
    _ = timers;
    try services.sendEvent(io, allocator, try ziggy.json.stringify(allocator, payload));
}

//
// The function of the tests' `.zig` menu item "failing-item", which fails.
//
fn menuItemFails(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!void {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    return error.MenuItemFailed;
}

//
// The tests' menu: a standard item, two `.zig` items, a separator, a `.ui` item and a submenu holding another `.ui` item.
//
pub const menu: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .label = "Quit",
                .accelerator = "CmdOrCtrl+Q",
                .run = .{
                    .standard = .quit,
                },
            },
        },
    },
    .{
        .label = "Example",
        .items = &.{
            .{
                .label = "Zig Item",
                .name = "zig-item",
                .run = .{
                    .zig = menuItemRan,
                },
            },
            .{
                .label = "Failing Item",
                .name = "failing-item",
                .run = .{
                    .zig = menuItemFails,
                },
            },
            ziggy.menu.separator,
            .{
                .label = "About",
                .name = "about",
                .run = .ui,
            },
            .{
                .label = "More",
                .items = &.{
                    .{
                        .label = "Nested",
                        .name = "nested",
                        .accelerator = "CmdOrCtrl+Shift+N",
                        .run = .ui,
                    },
                },
            },
        },
    },
};

//
// The tests' messages: echo, fail, none, name, greet, forget, count, and quick-request, fail-request, pick-open-request and
// pick-save-request, whose response is the result of the task quick, fail, pick-open or pick-save. App wants the task types as a
// struct literal, and the tests also add task types of their own to the list in task_handlers, so the app takes that list after App
// has made it.
//
pub const app = registered: {
    var registered = core.App(.{
        .messages = .{
            .echo = echoHandler,
            .fail = failHandler,
            .none = noneHandler,
            .name = nameHandler,
            .raw = rawHandler,
            .greet = greetHandler,
            .forget = forgetHandler,
            .count = countHandler,
            .@"quick-request" = respondedByTask("quick"),
            .@"fail-request" = respondedByTask("fail"),
            .@"pick-open-request" = respondedByTask("pick-open"),
            .@"pick-save-request" = respondedByTask("pick-save"),
            .@"send-app-event" = sendAppEventHandler,
        },
        .tasks = .{},
        .menu = menu,
        .ui_files = &[_]ziggy.ui_files.UiFile{
            .{
                .path = "index.html",
                .content = "<html></html>",
            },
        },
    });
    registered.tasks = &task_handlers;
    break :registered registered;
};

//
// Starts a core on the fake native app, with the test thread's Io and allocator. The test stops it with `native_app.stop`.
//
pub fn createCore(native_app: *FakeNativeApp, worker_threads: u32, max_children: u32) !void {
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(worker_threads, max_children), app);
}
