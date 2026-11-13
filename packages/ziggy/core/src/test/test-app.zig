//
// The app the core's tests start: its messages, its menu, its actions and the function that starts a core with it on the fake native
// app. Its task types are those of test-tasks.zig.
//

const std = @import("std");
const ziggy = @import("ziggy");
const test_tasks = @import("test-tasks.zig");

const core = ziggy.core;
const HandlerServices = core.HandlerServices;
const Timers = ziggy.timers.Timers;
const FakeNativeApp = ziggy.fake_native_app.FakeNativeApp;

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
// run-an-action: runs the tests' action "say-hello" through the handler services, as a handler of the app's would.
//
fn runAnActionHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: struct {}) !void {
    _ = timers;
    _ = payload;
    try services.runAction(io, allocator, "say-hello");
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
// The tests' actions, which the test app is given as `.actions`: "say-hello", which the menu has an `.action` item for; and
// "shortcut-only", "typing-only" and "ask", which it has none for. "typing-only" and "ask" have shortcuts with no Ctrl, Alt or Cmd,
// which the frontend runs rather than a native app.
//
pub const actions: []const ziggy.action.Action = &.{
    .{
        .name = "say-hello",
        .label = "Say Hello",
        .shortcut = "CmdOrCtrl+Shift+H",
    },
    .{
        .name = "shortcut-only",
        .label = "Shortcut Only",
        .shortcut = "CmdOrCtrl+Shift+O",
    },
    .{
        .name = "typing-only",
        .label = "Typing Only",
        .shortcut = "Escape",
    },
    .{
        .name = "ask",
        .label = "Ask",
        .shortcut = "?",
    },
};

//
// The tests' menu: a standard item, two `.zig` items, an `.action` item, a separator, a `.ui` item and a submenu holding another `.ui`
// item.
//
pub const menu: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .label = "Quit",
                .shortcut = "CmdOrCtrl+Q",
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
            .{
                .run = .{
                    .action = "say-hello",
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
                        .shortcut = "CmdOrCtrl+Shift+N",
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
            .@"run-an-action" = runAnActionHandler,
        },
        .tasks = .{},
        .menu = menu,
        .actions = actions,
        .ui_files = &[_]ziggy.ui_files.UiFile{
            .{
                .path = "index.html",
                .content = "<html></html>",
            },
        },
    });
    registered.tasks = &test_tasks.task_handlers;
    break :registered registered;
};

//
// Starts a core on the fake native app, with the test thread's Io and allocator. The test stops it with `native_app.stop`.
//
pub fn createCore(native_app: *FakeNativeApp, worker_threads: u32, max_children: u32) !void {
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(worker_threads, max_children), app);
}
