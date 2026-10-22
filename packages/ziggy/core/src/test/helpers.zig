//
// What the core's tests share: the shell stand-in, and small task handlers.
//

const std = @import("std");
const ziggy = @import("ziggy");

const core_module = ziggy.core;
const task_runner = ziggy.task_runner;

//
// A stand-in for a shell that records every message the core delivers.
//
pub const FakeShell = ziggy.fake_shell.FakeShell;

// Sleeps for a task, returning error.Cancelled early when the task is cancelled.
//
pub fn sleepOrCancel(context: *task_runner.TaskContext, milliseconds: i64) !void {
    var remaining = milliseconds;
    while (remaining > 0) : (remaining -= 1) {
        try context.checkCancelled();
        try context.io().sleep(.fromMilliseconds(1), .awake);
    }
    try context.checkCancelled();
}

fn quickTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    try context.sendMessage(.{ .text = "hello" });
    return try context.arena.dupe(u8, "\"done\"");
}

fn spinTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    var step: u32 = 0;
    while (true) : (step += 1) {
        try context.checkCancelled();
        try context.sendMessage(.{ .step = step });
        try context.io().sleep(.fromMilliseconds(2), .awake);
    }
}

fn failTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    _ = data;
    return error.TestFailure;
}

fn sleepTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const milliseconds = ziggy.json.getInteger(data, "ms") orelse 0;
    const name = ziggy.json.getString(data, "name") orelse "sleep";
    try context.sendMessage(.{ .start = name });
    try sleepOrCancel(context, milliseconds);
    try context.sendMessage(.{ .end = name });
    return null;
}

fn parentTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const children = ziggy.json.getInteger(data, "children") orelse 0;
    const child_ms = ziggy.json.getInteger(data, "childMs") orelse 5;
    const parent_name = ziggy.json.getString(data, "name") orelse "parent";
    var index: i64 = 0;
    while (index < children) : (index += 1) {
        _ = try context.queueChild("child", .{ .name = parent_name, .ms = child_ms }, null);
    }
    context.awaitAllTasks();
    try context.sendMessage(.{ .allChildrenDone = parent_name });
    return null;
}

fn awaitOneTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const first = try context.queueChild("child-result", .{}, null);
    const second = try context.queueChild("fail", .{}, null);
    const first_completion = try context.awaitTask(first);
    const second_completion = try context.awaitTask(second);
    return try ziggy.json.stringify(context.arena, .{
        .first = @tagName(first_completion.status),
        .firstResult = ziggy.json.Raw{ .text = first_completion.result_json orelse "null" },
        .second = @tagName(second_completion.status),
        .secondError = second_completion.error_message orelse "",
    });
}

fn runChildrenInTurnTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const first = try context.runChild(allocator, "child-result", .{}, null);
    const second = try context.runChild(allocator, "fail", .{}, null);
    const third = try context.runChild(allocator, "child-result", .{}, null);
    return try ziggy.json.stringify(context.arena, .{
        .first = @tagName(first.status),
        .firstResult = ziggy.json.Raw{ .text = first.result_json orelse "null" },
        .second = @tagName(second.status),
        .secondError = second.error_message orelse "",
        .third = @tagName(third.status),
        .thirdResult = ziggy.json.Raw{ .text = third.result_json orelse "null" },
    });
}

fn childResultTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    return try context.arena.dupe(u8, "\"child answer\"");
}

fn childTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const milliseconds = ziggy.json.getInteger(data, "ms") orelse 0;
    const name = ziggy.json.getString(data, "name") orelse "child";
    try context.sendMessage(.{ .childStart = name });
    try sleepOrCancel(context, milliseconds);
    try context.sendMessage(.{ .childEnd = name });
    return null;
}

fn blockedParentTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    _ = try context.queueChild("child", .{ .name = "blocked", .ms = 100000 }, null);
    _ = try context.queueChild("child", .{ .name = "blocked", .ms = 100000 }, null);
    context.awaitAllTasks();
    try context.checkCancelled();
    return null;
}

fn flooderTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const count = ziggy.json.getInteger(data, "count") orelse 0;
    var index: i64 = 0;
    while (index < count) : (index += 1) {
        try context.sendMessage(.{ .seq = index });
    }
    return null;
}

//
// The task handlers the tests register.
//
pub const task_handlers = [_]task_runner.TaskHandlerEntry{
    .{ .name = "quick", .handler = quickTask },
    .{ .name = "spin", .handler = spinTask },
    .{ .name = "fail", .handler = failTask },
    .{ .name = "sleep", .handler = sleepTask },
    .{ .name = "parent", .handler = parentTask },
    .{ .name = "child", .handler = childTask },
    .{ .name = "child-result", .handler = childResultTask },
    .{ .name = "await-one", .handler = awaitOneTask },
    .{ .name = "run-children-in-turn", .handler = runChildrenInTurnTask },
    .{ .name = "blocked-parent", .handler = blockedParentTask },
    .{ .name = "flooder", .handler = flooderTask },
    .{ .name = "pick-open", .handler = pickOpenTask },
    .{ .name = "pick-save", .handler = pickSaveTask },
    .{ .name = "keep-sleep", .handler = sleepTask, .kind = .keep_alive },
    .{ .name = "keep-parent", .handler = parentTask, .kind = .keep_alive },
};
fn pickOpenTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const title: ?[]const u8 = if (data == .string) data.string else null;
    return try context.pickPaths(.open_files, title, null);
}

fn pickSaveTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const initial_name: ?[]const u8 = if (data == .string) data.string else null;
    return try context.pickPaths(.save_file, null, initial_name);
}


//
// echo: the message response is the message's data, unparsed.
//
fn echoHandler(core: *core_module.Core, arena: std.mem.Allocator, message: core_module.Message) anyerror!core_module.MessageResult {
    _ = core;
    return .{
        .response = try ziggy.json.stringify(arena, message.data),
    };
}

//
// fail: fails with error.HandlerFailed, whatever the data.
//
fn failHandler(core: *core_module.Core, arena: std.mem.Allocator, request: std.json.Value) anyerror!void {
    _ = core;
    _ = arena;
    _ = request;
    return error.HandlerFailed;
}

//
// none: returns none, so a message with an id gets an empty successful message response.
//
fn noneHandler(core: *core_module.Core, arena: std.mem.Allocator, message: core_module.Message) anyerror!core_module.MessageResult {
    _ = core;
    _ = arena;
    _ = message;
    return .none;
}

//
// name: the message response is the message's name, so a test can see the name reached the handler unchanged.
//
fn nameHandler(core: *core_module.Core, arena: std.mem.Allocator, message: core_module.Message) anyerror!core_module.MessageResult {
    _ = core;
    return .{
        .response = try ziggy.json.stringify(arena, message.name),
    };
}


//
// raw: the message response is the message's name, id and data as they arrived, so a test can see the handler that takes
// ziggy.core.Message gets the message unparsed.
//
fn rawHandler(core: *core_module.Core, arena: std.mem.Allocator, message: core_module.Message) anyerror!core_module.MessageResult {
    _ = core;
    return .{
        .response = try ziggy.json.stringify(arena, .{
            .name = message.name,
            .id = message.id,
            .data = message.data,
        }),
    };
}
//
// Makes the handler of a message answered by a task of the given type, whose input is the message's data.
//
fn answeredByTask(comptime task_type: []const u8) fn (core: *core_module.Core, arena: std.mem.Allocator, message: core_module.Message) anyerror!core_module.MessageResult {
    return struct {
        fn handle(core: *core_module.Core, arena: std.mem.Allocator, message: core_module.Message) anyerror!core_module.MessageResult {
            return try core.answerWithTask(message, task_type, try ziggy.json.stringify(arena, message.data));
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
// greet: a handler with a typed request and response, which answers with a greeting built from the request's fields.
//
fn greetHandler(core: *core_module.Core, arena: std.mem.Allocator, request: GreetRequest) !GreetResponse {
    _ = core;
    return .{
        .text = try std.fmt.allocPrint(arena, "Hello {s}{s}", .{ request.title orelse "", request.name }),
        .times = request.times,
    };
}

//
// forget: a handler with a typed request that returns nothing, so a message with an id gets a successful message response
// holding null. It delivers what it was given, so a test can see it ran and with which data.
//
fn forgetHandler(core: *core_module.Core, arena: std.mem.Allocator, request: GreetRequest) !void {
    core.deliver(try std.fmt.allocPrint(arena, "forgot {s} {d}", .{ request.name, request.times }));
}

//
// count: a handler whose request is not a struct.
//
fn countHandler(core: *core_module.Core, arena: std.mem.Allocator, request: []const u32) !usize {
    _ = core;
    _ = arena;
    return request.len;
}

//
// The function of the tests' `.zig` menu item "zig-item": it delivers a line, so a test can see it ran on this core.
//
fn menuItemRan(core: *core_module.Core, arena: std.mem.Allocator) anyerror!void {
    _ = arena;
    core.deliver("{\"data\":\"the menu item's function ran\"}");
}

//
// The function of the tests' `.zig` menu item "failing-item", which fails.
//
fn menuItemFails(core: *core_module.Core, arena: std.mem.Allocator) anyerror!void {
    _ = core;
    _ = arena;
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
// pick-save-request, which are answered by the task quick, fail, pick-open or pick-save. App wants the task types as a struct
// literal, and the tests also add task types of their own to the list in task_handlers, so the app takes that list after App has
// made it.
//
pub const app = registered: {
    var registered = core_module.App(.{
        .messages = .{
            .echo = echoHandler,
            .fail = failHandler,
            .none = noneHandler,
            .name = nameHandler,
            .raw = rawHandler,
            .greet = greetHandler,
            .forget = forgetHandler,
            .count = countHandler,
            .@"quick-request" = answeredByTask("quick"),
            .@"fail-request" = answeredByTask("fail"),
            .@"pick-open-request" = answeredByTask("pick-open"),
            .@"pick-save-request" = answeredByTask("pick-save"),
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
// Creates a core on the fake shell.
//
pub fn createCore(shell: *FakeShell, worker_threads: u32, max_children: u32) !*core_module.Core {
    return try core_module.Core.create(std.testing.allocator, shell.config(worker_threads, max_children), app);
}
