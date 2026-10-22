//
// The task runner's system messages: add-task, which queues a task the frontend names, and cancel-tasks, which cancels the
// tasks queued under a source.
//

const std = @import("std");
const json = @import("../json.zig");
const task_runner = @import("../task-runner.zig");
const core_lib = @import("../core.zig");
const message_registry = @import("../message-registry.zig");

const Core = core_lib.Core;

//
// Registers the task runner's system messages. The core calls it once the task runner is running.
//
pub fn register(registry: *message_registry.Registry) !void {
    try registry.register("add-task", addTaskHandler);
    try registry.register("cancel-tasks", cancelTasksHandler);
}

//
// The data of add-task: the task the frontend queues.
//
const AddTaskRequest = struct {
    // The task's id, which its events carry.
    taskId: []const u8,
    // The task type, which names its handler.
    taskType: []const u8,
    // The source the task is queued under, which cancel-tasks cancels by.
    source: []const u8,
    // The task's input, or null for none.
    data: std.json.Value = .null,
    // Whether the task runs before background ones, or null for background.
    priority: ?task_runner.TaskPriority = null,
};

//
// The message response to add-task and to cancel-tasks, an empty object.
//
const DoneResponse = struct {};

//
// Handles add-task: queues the task the frontend's add-task message names.
//
fn addTaskHandler(core: *Core, arena: std.mem.Allocator, request: AddTaskRequest) !DoneResponse {
    const data_json = try json.stringify(arena, request.data);
    try core.runner.addTask(request.taskId, request.taskType, request.source, data_json, request.priority orelse .background, null);
    return .{};
}

//
// Handles cancel-tasks: cancels the tasks queued under the source, which the frontend sends as a bare string.
//
fn cancelTasksHandler(core: *Core, arena: std.mem.Allocator, source: []const u8) !DoneResponse {
    _ = arena;
    core.runner.cancelSource(source);
    return .{};
}
