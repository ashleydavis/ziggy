//
// Hello world example: change it into your own code, or delete it.
//
// The two kinds of Zig code an app's UI uses: a message handler, which answers a message from the UI straight away, and a task,
// which does slower work on a thread of its own and reports back while it runs.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");

const TaskContext = ziggy.task_runner.TaskContext;

//
// Answers the UI's hello-world message with a greeting for the name in the message's data, naming the platform the app runs on.
//
pub fn helloWorldHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = core;
    const name = ziggy.json_util.getString(data, "name") orelse {
        return error.MissingName;
    };
    return try ziggy.json_util.stringify(arena, .{
        .greeting = try std.fmt.allocPrint(arena, "Hello {s}, from Zig on {s}", .{
            name,
            @tagName(builtin.os.tag),
        }),
    });
}

//
// The hello-world task: sends the UI one output message while it runs, then completes with a result.
//
pub fn helloWorldTaskHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    try context.sendMessage(.{
        .type = "output",
        .text = "Hello world from a task",
    });
    return try context.arena.dupe(u8, "\"hello world task done\"");
}
