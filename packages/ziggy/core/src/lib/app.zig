//
// ziggy.core.App: how an app registers itself with Ziggy's core. The app lists its message handlers by name and its task handlers by
// task type, and App checks every one when the app is built. Each message handler takes one of the forms handlers.zig describes.
//

const std = @import("std");
const core_lib = @import("core.zig");
const handlers = @import("handlers.zig");
const task_runner = @import("task-runner.zig");
const menu_lib = @import("menu.zig");

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
        .name = "state",
        .required = false,
    },
    .{
        .name = "on_task_end",
        .required = false,
    },
    .{
        .name = "on_task_message",
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
//   .tasks            each field a task type and its task handler, or `.{ .handler = ..., .kind = .keep_alive }` for a task type
//                     the app is kept running for
//   .menu             the desktop menu, a []const ziggy.menu.Menu (see menu.zig), checked when the app is built
//   .ui_files         the files of the app's bundled UI
//   .describe_error, .state, .on_task_end, .on_task_message, .ui_query   optional, as RegisteredApp describes them
//
// Every field and every handler is checked when the app is built: a field App does not know, a missing one or a handler of the wrong
// type fails the build with a message that names it. Ziggy's build exports the C interface and the Android entry points for the
// `app` declaration of the app's backend source file, so the app declares `pub const app = ziggy.core.App(.{ ... });` and nothing
// else.
//
pub fn App(comptime definition: anytype) core_lib.RegisteredApp {
    const Definition = @TypeOf(definition);
    comptime {
        if (@typeInfo(Definition) != .@"struct") {
            @compileError("ziggy.core.App takes a struct literal such as .{ .messages = .{ ... }, .tasks = .{ ... }, ... }");
        }
        for (@typeInfo(Definition).@"struct".fields) |field| {
            if (!isAppField(field.name)) {
                @compileError("ziggy.core.App: there is no field \"" ++ field.name ++ "\". The fields are messages, tasks, menu, ui_files, describe_error, state, on_task_end, on_task_message and ui_query.");
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
        .state = if (@hasField(Definition, "state")) definition.state else null,
        .on_task_end = if (@hasField(Definition, "on_task_end")) definition.on_task_end else null,
        .on_task_message = if (@hasField(Definition, "on_task_message")) definition.on_task_message else null,
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
        entries[index] = .{
            .name = field.name,
            .handler = handlers.wrapNamed("the message \"" ++ field.name ++ "\"", @field(messages, field.name)),
        };
    }
    const final_entries = entries;
    return &final_entries;
}

//
// Makes the list of the app's task types from the fields of `.tasks`.
//
fn taskTable(comptime tasks: anytype) []const task_runner.TaskHandlerEntry {
    const Tasks = @TypeOf(tasks);
    if (@typeInfo(Tasks) != .@"struct") {
        @compileError("ziggy.core.App: .tasks must be a struct literal whose fields are task types and their handlers, such as .{ .@\"hello-world-task\" = helloWorldTaskHandler }.");
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
// normal. `label` names the task type in a compile error.
//
pub fn taskEntry(comptime label: []const u8, name: []const u8, comptime task: anytype) task_runner.TaskHandlerEntry {
    const TaskFunction = @typeInfo(task_runner.TaskHandler).pointer.child;
    const Task = @TypeOf(task);
    const signature = "fn (context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8";
    if (Task == TaskFunction or Task == task_runner.TaskHandler) {
        return .{
            .name = name,
            .handler = task,
        };
    }
    if (@typeInfo(Task) == .@"struct" and @hasField(Task, "handler") and @hasField(Task, "kind") and @typeInfo(Task).@"struct".fields.len == 2) {
        if (@TypeOf(task.handler) != TaskFunction and @TypeOf(task.handler) != task_runner.TaskHandler) {
            @compileError("ziggy.core: the handler of " ++ label ++ " has the wrong type. A task handler is " ++ signature ++ ".");
        }
        return .{
            .name = name,
            .handler = task.handler,
            .kind = task.kind,
        };
    }
    @compileError("ziggy.core: " ++ label ++ " must be given a task handler, " ++ signature ++ ", or .{ .handler = ..., .kind = ... }.");
}
