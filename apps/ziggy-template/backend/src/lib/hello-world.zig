//
// Hello world example: change it into your own code, or delete it.
//
// The kinds of Zig code an app's frontend uses: a message handler, which returns the message response to a message from the frontend
// straight away, a task, which does slower work on a thread of its own and reports back while it runs, and a menu item's function,
// which sends the frontend an event. Each takes the same standard arguments as every other of its kind: its services, the timers, the
// Io and an allocator, then (for a task) its context, then the payload.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");

const HandlerServices = ziggy.core.HandlerServices;
const TaskServices = ziggy.task_runner.TaskServices;
const TaskContext = ziggy.task_runner.TaskContext;
const Timers = ziggy.timers.Timers;

//
// The data of the frontend's hello-world message.
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
// Handles the frontend's hello-world message: returns a greeting for the name in the message's data, naming the platform the app runs on.
//
pub fn helloWorldHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: HelloWorldRequest) !HelloWorldResponse {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .greeting = try std.fmt.allocPrint(allocator, "Hello {s}, from Zig on {s}", .{
            payload.name,
            @tagName(builtin.os.tag),
        }),
    };
}

//
// The hello-world task: sends the frontend one output event while it runs, then completes with a result.
//
pub fn helloWorldTaskHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) ![]const u8 {
    _ = timers;
    _ = context;
    _ = payload;
    try services.sendEvent(io, allocator, .{
        .type = "output",
        .text = "Hello world from a task",
    });
    return "hello world task done";
}

//
// The Hello menu's Say Hello From Zig item: sends the frontend the app event {"type": "hello-from-zig", "text": ...}, which the
// frontend writes to its log. It runs on the thread that handles messages, like a message handler, so it must be quick: slow work
// queues a task from it.
//
pub fn helloFromZigMenuItem(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) !void {
    _ = timers;
    try services.sendEvent(io, allocator, "{\"type\":\"hello-from-zig\",\"text\":\"Hello from Zig, run from the menu\"}");
}
