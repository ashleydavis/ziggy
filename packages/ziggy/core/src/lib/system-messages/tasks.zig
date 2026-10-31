//
// The worker pool's system messages: add-task, which queues a task the frontend names, and cancel-tasks, which cancels the
// tasks queued under a source.
//

const std = @import("std");
const json = @import("../json.zig");
const task_runner = @import("../task-runner.zig");
const worker_pool = @import("../worker-pool.zig");
const ILog = @import("log").ILog;

//
// The data of add-task: the task the frontend queues.
//
pub const AddTaskRequest = struct {
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
pub const DoneResponse = struct {};

//
// Handles add-task: queues the task the frontend's add-task message names.
//
pub fn addTask(pool: *worker_pool.WorkerPool, io: std.Io, allocator: std.mem.Allocator, log: ILog, request: AddTaskRequest) !DoneResponse {
    const data_json = try json.stringify(allocator, request.data);
    defer allocator.free(data_json);
    try pool.addTask(io, allocator, log, request.taskId, request.taskType, request.source, data_json, request.priority orelse .background, null);
    return .{};
}

//
// Handles cancel-tasks: cancels the tasks queued under the source, which the frontend sends as a bare string.
//
pub fn cancelTasks(pool: *worker_pool.WorkerPool, io: std.Io, allocator: std.mem.Allocator, log: ILog, source: []const u8) DoneResponse {
    pool.cancelSource(io, allocator, log, source);
    return .{};
}
