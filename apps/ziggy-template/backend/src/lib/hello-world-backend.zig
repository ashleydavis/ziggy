//
// Hello world example: change it into your own code, or delete it.
//
// The two kinds of Zig code an app's UI uses: a message handler, which returns the message response to a message from the UI straight away, and a task,
// which does slower work on a thread of its own and reports back while it runs.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");

const TaskContext = ziggy.task_runner.TaskContext;

//
// The data of the UI's hello-world message.
//
pub const HelloWorldRequest = struct {
    // Who to greet.
    name: []const u8,
};

//
// The message response to the hello-world message.
//
pub const HelloWorldResponse = struct {
    // The greeting, naming the platform the app runs on.
    greeting: []const u8,
};

//
// Handles the UI's hello-world message: returns a greeting for the name in the message's data, naming the platform the app runs on.
//
pub fn helloWorldHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: HelloWorldRequest) !HelloWorldResponse {
    _ = core;
    return .{
        .greeting = try std.fmt.allocPrint(arena, "Hello {s}, from Zig on {s}", .{
            request.name,
            @tagName(builtin.os.tag),
        }),
    };
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
