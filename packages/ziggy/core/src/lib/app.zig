//
// ziggy.core.App: how an app registers itself with Ziggy's core. The app lists its message handlers by name and its task handlers by
// task type, and App checks every one when the app is built. Each message handler takes one of the forms handlers.zig describes and
// each task handler the form task-runner.zig describes.
//

const std = @import("std");
const types = @import("types.zig");
const handlers = @import("handlers.zig");
const task_runner = @import("task-runner.zig");
const menu_lib = @import("menu.zig");
const ui_files = @import("ui-files.zig");
const services_lib = @import("services.zig");
const timers_lib = @import("timers.zig");
const task_queue_types = @import("task-queue.zig").types;

const HandlerServices = services_lib.HandlerServices;
const Timers = timers_lib.Timers;

//
// An app as App registered it: what the app adds to the core. An app makes it with App and never writes one itself.
//
pub const RegisteredApp = struct {
    // The app's message handlers by message name, each wrapped by App. Only app messages reach them, never a system message. A
    // handler that fails returns an error, which becomes an error message response (or a core-error event for a message with no
    // id).
    messages: []const handlers.MessageEntry,
    // The app's task types.
    tasks: []const task_runner.TaskHandlerEntry,
    // The desktop menu as JSON, which App makes from the app's `.menu` (see menuJson in menu.zig). "[]" for an app with no menu.
    // Native apps show it on desktop only. See "Menus" in the architecture document.
    menu_json: []const u8,
    // What the core does for each menu item a native app posts as menu-action, by the item's name, which App makes from the app's
    // `.menu` (see menuTargets in menu.zig).
    menu_targets: menu_lib.MenuTargets,
    // The files of the app's bundled frontend, embedded in the app's library, for a native app that serves the frontend by
    // calling the core for each file (the MacOS, iOS and Android native apps). Empty for an app whose native app embeds the
    // frontend itself.
    ui_files: []const ui_files.UiFile,
    // Turns the error a handler returned into the text of the error response, for an app whose code reports the reason for a failure
    // somewhere other than the error's name (a Zig error carries no message). It returns null when it has nothing to add about the
    // error, and the response then carries the error's name. It is called on the thread that handled the message (the main thread) or
    // ran the task (a worker), straight after the handler failed, and the text is used before the call returns.
    describe_error: ?types.ErrorDescriber = null,
    // Called on the main thread when a task has ended, after the frontend has been told. The values are valid only during the call.
    on_task_end: ?OnTaskEnd = null,
    // Called on the main thread when a task has sent an event, after the frontend has been told. The values are valid only during
    // the call.
    on_task_event: ?OnTaskEvent = null,
    // Gives the query text the native app appends to the address of the frontend, after the question mark, so the frontend's
    // first render already holds what the app tells it at start-up. Null for an app whose frontend needs no query. See `UiQuery`.
    ui_query: ?UiQuery = null,
    // Called once on the main thread when it starts, before any message or task can reach the app, so the app can make what its
    // handlers and tasks need. An error stops the main thread, after it has released what it made, and the core's start fails with
    // that error. Null for an app with nothing to do then. The counterpart of `on_destroy`.
    on_create: ?OnCreate = null,
    // Called twice on the main thread while it stops: with `.before_tasks_stop` while tasks can still be queued, so the app can stop
    // its own threads, and with `.after_tasks_stopped` once every task has ended, so the app can free its own resources. The main
    // thread stops whenever the native app ends the backend, which is not only when the app quits (an Android activity's onDestroy,
    // for one), and in tests. Null for an app with nothing to do then. See `DestroyPhase`.
    on_destroy: ?OnDestroy = null,
};

//
// The app's function called when the main thread starts (see `RegisteredApp.on_create`), with the standard arguments of a handler.
//
pub const OnCreate = *const fn (services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!void;

//
// The app's function called while the main thread stops (see `RegisteredApp.on_destroy`), with the standard arguments of a handler
// and the point of the stop.
//
pub const OnDestroy = *const fn (services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, phase: DestroyPhase) void;

//
// The app's function called when a task has ended (see `RegisteredApp.on_task_end`), with the standard arguments of a handler.
//
pub const OnTaskEnd = *const fn (services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, end: types.TaskEnd) void;

//
// The app's function called when a task has sent an event (see `RegisteredApp.on_task_event`), with the standard arguments of a
// handler.
//
pub const OnTaskEvent = *const fn (services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, sent: types.TaskSentEvent) void;

//
// An app's function for the query of the frontend's address. The main thread calls it, with the standard arguments of a handler, when
// the native app calls ziggy_ui_query (the native app calls it once the core exists, before it loads the frontend), with whether the
// test mode switch is on, which the app puts in the query however it likes. It returns the text after the question mark, such as
// `restApiUrl=...&testMode=1`, or an empty string for no query, allocated with the allocator given. Ziggy passes the text through
// unread, so no native app composes a query and Ziggy names none of its parts.
//
pub const UiQuery = *const fn (services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, test_mode: bool) anyerror![]const u8;

//
// The point of the main thread's stop at which the app's `on_destroy` is called.
//
pub const DestroyPhase = enum {
    // First, before the workers stop: tasks can still be queued and the ones running are still running. For stopping the app's own
    // threads, which may still queue tasks.
    before_tasks_stop,
    // Second, after the workers have stopped: every task has ended and no task can be queued. For freeing what the app's own code
    // allocated, now that no task can use it.
    after_tasks_stopped,
};

//
// The fields App takes, with whether each must be given.
//
const AppField = struct {
    // The field's name.
    name: []const u8,
    // Whether an app must give it.
    required: bool,
};

//
// Every field of the struct given to App.
//
const app_fields = [_]AppField{
    .{
        .name = "messages",
        .required = true,
    },
    .{
        .name = "tasks",
        .required = true,
    },
    .{
        .name = "menu",
        .required = true,
    },
    .{
        .name = "ui_files",
        .required = true,
    },
    .{
        .name = "describe_error",
        .required = false,
    },
    .{
        .name = "on_task_end",
        .required = false,
    },
    .{
        .name = "on_create",
        .required = false,
    },
    .{
        .name = "on_destroy",
        .required = false,
    },
    .{
        .name = "on_task_event",
        .required = false,
    },
    .{
        .name = "ui_query",
        .required = false,
    },
};

//
// Registers an app with Ziggy's core. `definition` is a struct literal:
//
//   .messages         each field a message name and the handler for it (see wrapNamed in handlers.zig for the forms a handler takes)
//   .tasks            each field a task type and its task handler (see wrapTask in task-runner.zig), or `.{ .handler = ..., .kind =
//                     .keep_alive }` for a task type the app is kept running for
//   .menu             the desktop menu, a []const ziggy.menu.Menu (see menu.zig), checked when the app is built
//   .ui_files         the files of the app's bundled frontend
//   .describe_error, .on_task_end, .on_task_event, .on_create, .on_destroy, .ui_query   optional, as RegisteredApp describes them
//
// Every field and every handler is checked when the app is built: a field App does not know, a missing one or a handler of the wrong
// type fails the build with a message that names it. Ziggy's build exports the C interface and the Android entry points for the
// `app` declaration of the app's backend source file, so the app declares `pub const app = ziggy.core.App(.{ ... });` and nothing
// else.
//
pub fn App(comptime definition: anytype) RegisteredApp {
    const Definition = @TypeOf(definition);
    comptime {
        if (@typeInfo(Definition) != .@"struct") {
            @compileError("ziggy.core.App takes a struct literal such as .{ .messages = .{ ... }, .tasks = .{ ... }, ... }");
        }
        for (@typeInfo(Definition).@"struct".fields) |field| {
            if (!isAppField(field.name)) {
                @compileError("ziggy.core.App: there is no field \"" ++ field.name ++ "\". The fields are messages, tasks, menu, ui_files, describe_error, on_task_end, on_task_event, on_create, on_destroy and ui_query.");
            }
        }
        for (app_fields) |field| {
            if (field.required and !@hasField(Definition, field.name)) {
                @compileError("ziggy.core.App: the field \"" ++ field.name ++ "\" is missing.");
            }
        }
        menu_lib.checkMenu(definition.menu);
    }
    return .{
        .messages = comptime messageTable(definition.messages),
        .tasks = comptime taskTable(definition.tasks),
        .menu_json = comptime menu_lib.menuJson(definition.menu),
        .menu_targets = comptime menu_lib.menuTargets(definition.menu),
        .ui_files = definition.ui_files,
        .describe_error = if (@hasField(Definition, "describe_error")) definition.describe_error else null,
        .on_task_end = if (@hasField(Definition, "on_task_end")) definition.on_task_end else null,
        .on_task_event = if (@hasField(Definition, "on_task_event")) definition.on_task_event else null,
        .on_create = if (@hasField(Definition, "on_create")) definition.on_create else null,
        .on_destroy = if (@hasField(Definition, "on_destroy")) definition.on_destroy else null,
        .ui_query = if (@hasField(Definition, "ui_query")) definition.ui_query else null,
    };
}

//
// Whether App has a field of this name.
//
fn isAppField(comptime name: []const u8) bool {
    for (app_fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return true;
        }
    }
    return false;
}

//
// Makes the list of the app's message handlers, each wrapped, from the fields of `.messages`.
//
fn messageTable(comptime messages: anytype) []const handlers.MessageEntry {
    const Messages = @TypeOf(messages);
    if (@typeInfo(Messages) != .@"struct") {
        @compileError("ziggy.core.App: .messages must be a struct literal whose fields are message names and their handlers, such as .{ .@\"hello-world\" = helloWorldHandler }.");
    }
    const fields = @typeInfo(Messages).@"struct".fields;
    var entries: [fields.len]handlers.MessageEntry = undefined;
    for (fields, 0..) |field, index| {
        entries[index] = handlers.wrapNamed("the message \"" ++ field.name ++ "\"", @field(messages, field.name));
        entries[index].name = field.name;
    }
    const final_entries = entries;
    return &final_entries;
}

//
// Makes the list of the app's task types from the fields of `.tasks`.
//
pub fn taskTable(comptime tasks: anytype) []const task_runner.TaskHandlerEntry {
    const Tasks = @TypeOf(tasks);
    if (@typeInfo(Tasks) != .@"struct") {
        @compileError("ziggy.core.App: .tasks must be a struct literal whose fields are task types and their handlers, such as .{ .@\"hello-world-task\" = helloWorldTask }.");
    }
    const fields = @typeInfo(Tasks).@"struct".fields;
    var entries: [fields.len]task_runner.TaskHandlerEntry = undefined;
    for (fields, 0..) |field, index| {
        entries[index] = taskEntry("the task type \"" ++ field.name ++ "\"", field.name, @field(tasks, field.name));
    }
    const final_entries = entries;
    return &final_entries;
}

//
// The entry of a task type: `task` is a task handler, or `.{ .handler = ..., .kind = ... }` for a task type of another kind than
// normal. A task handler is Ziggy's raw TaskHandler, used as it is, a typed one (see wrapTask in task-runner.zig) or one written against the task queue package (it takes
// an allocator, an Io, the data and an ITaskContext, and returns its outputs as a JSON value). `label` names the task type in a compile
// error.
//
pub fn taskEntry(comptime label: []const u8, name: []const u8, comptime task: anytype) task_runner.TaskHandlerEntry {
    const Task = @TypeOf(task);
    if (@typeInfo(Task) == .@"struct" and @hasField(Task, "handler") and @hasField(Task, "kind") and @typeInfo(Task).@"struct".fields.len == 2) {
        return .{
            .name = name,
            .handler = toTaskHandler(label, task.handler),
            .kind = task.kind,
        };
    }
    return .{
        .name = name,
        .handler = toTaskHandler(label, task),
    };
}

//
// The task handler for a function of either form taskEntry takes. A function that is neither fails the build with wrapTask's message.
//
fn toTaskHandler(comptime label: []const u8, comptime function: anytype) task_runner.TaskHandler {
    const Function = @TypeOf(function);
    const QueueFunction = @typeInfo(task_queue_types.TaskHandler).pointer.child;
    const RawFunction = @typeInfo(task_runner.TaskHandler).pointer.child;
    if (Function == RawFunction or Function == task_runner.TaskHandler) {
        return function;
    }
    if (Function == QueueFunction or Function == task_queue_types.TaskHandler) {
        return task_runner.fromQueueHandler(function);
    }
    return task_runner.wrapTask(label, function);
}
