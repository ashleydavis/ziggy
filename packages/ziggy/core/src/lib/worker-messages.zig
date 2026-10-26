//
// The messages the main thread and the workers send each other, each laid out as the TypeScript interface of the same name in the
// TypeScript worker pools (worker-pool-electron-main.ts, worker-log-electron.ts and worker-pool-bun.ts), so each encodes to the JSON
// the TypeScript sends. `native-app-request` and `native-app-response` have no TypeScript counterpart: they carry a task's request
// to the native app through the main thread.
//
// Every message is a JSON object whose "type" names it. A message is sent as JSON text, which the thread that takes it parses.
//

const std = @import("std");
const json = @import("json.zig");
const task_queue_types = @import("task-queue/types.zig");

const ITaskResult = task_queue_types.ITaskResult;
const TaskPriority = task_queue_types.TaskPriority;

//
// The main thread tells a worker to run a task ("execute").
//
pub const IWorkerMessage = struct {
    // Always "execute".
    type: []const u8 = "execute",
    // The id of the task to run.
    taskId: []const u8,
    // The task type, which names the handler the worker runs.
    taskType: []const u8,
    // The task's input.
    data: std.json.Value,
    // The source the task was queued under, which a cancel names.
    source: []const u8,
};

//
// The main thread tells every worker that the tasks of a source are cancelled ("cancel-tasks").
//
pub const IWorkerCancelTasksMessage = struct {
    // Always "cancel-tasks".
    type: []const u8 = "cancel-tasks",
    // The source whose tasks are cancelled.
    source: []const u8,
};

//
// The main thread tells a worker to end ("shutdown"). The worker finishes the task it is running first.
//
pub const IWorkerShutdownMessage = struct {
    // Always "shutdown".
    type: []const u8 = "shutdown",
};

//
// A worker tells the main thread it has started and is ready for a task ("worker-ready"), once.
//
pub const IWorkerReadyMessage = struct {
    // Always "worker-ready".
    type: []const u8 = "worker-ready",
};

//
// A task has ended ("task-completed"): a worker tells the main thread about the task it ran, and the main thread tells the worker
// whose task queued it about a child task.
//
pub const IWorkerTaskCompletedMessage = struct {
    // Always "task-completed".
    type: []const u8 = "task-completed",
    // The id of the task that ended.
    taskId: []const u8,
    // How it ended.
    result: ITaskResult,
};

//
// A task sent an event ("task-message"): a worker tells the main thread, which tells the frontend and the app.
//
pub const IWorkerTaskMessage = struct {
    // Always "task-message".
    type: []const u8 = "task-message",
    // The id of the task that sent it.
    taskId: []const u8,
    // The event, the task's own to lay out.
    message: std.json.Value,
};

//
// A running task queues a child task ("queue-task"): a worker has the main thread add it to the task list.
//
pub const IWorkerQueueTaskMessage = struct {
    // Always "queue-task".
    type: []const u8 = "queue-task",
    // The id the worker gave the child, which the main thread uses.
    taskId: []const u8,
    // The child's task type.
    taskType: []const u8,
    // The child's input.
    data: std.json.Value,
    // The source the child is queued under.
    source: []const u8,
    // The priority the worker requested, or null to run at the priority of the task that queued this one.
    priority: ?TaskPriority = null,
};

//
// The level of a worker's log line, the log's own.
//
pub const LogLevel = @import("task-queue/utils/log.zig").LogLevel;

//
// The output of a tool that a worker logs at the "tool" level.
//
pub const IToolData = struct {
    // What the tool wrote to stdout, when it wrote anything.
    stdout: ?[]const u8 = null,
    // What the tool wrote to stderr, when it wrote anything.
    stderr: ?[]const u8 = null,
};

//
// A worker logs a line ("log"). Only the main thread writes stdout, stderr and log files, so a worker sends its lines here.
//
pub const IWorkerLogMessage = struct {
    // Always "log".
    type: []const u8 = "log",
    // The level of the line.
    level: LogLevel,
    // The line.
    message: []const u8,
    // For the "exception" level, the error and what caused it.
    @"error": ?[]const u8 = null,
    // For the "tool" level, what the tool wrote.
    toolData: ?IToolData = null,
};

//
// A worker could not start ("worker-error"), and its thread has ended. In TypeScript an error a worker throws while it starts reaches the
// pool as the worker's "error" event, or as its "exit" event when it ends a process.
//
pub const IWorkerErrorMessage = struct {
    // Always "worker-error".
    type: []const u8 = "worker-error",
    // Why the worker could not start.
    message: []const u8,
};

//
// A worker wrote a line to its console ("console"). In TypeScript a worker thread's console output reaches the process's stdout or
// stderr as it is, apart from its log, so it is a message of its own here, which the main thread writes as it is.
//
pub const IWorkerConsoleMessage = struct {
    // Always "console".
    type: []const u8 = "console",
    // The stream the line was written to: "stdout" or "stderr".
    stream: []const u8,
    // The line.
    line: []const u8,
};

//
// A task has the native app do something only it can do ("native-app-request"), such as show a file dialog. The worker sends it
// to the main thread, which calls the native app and sends the result back as `native-app-response`.
//
pub const INativeAppRequestMessage = struct {
    // Always "native-app-request".
    type: []const u8 = "native-app-request",
    // Numbers the request among the requests of its worker, so the response can be matched with it.
    requestId: u64,
    // The native function to call: "pick-paths", "native-call" or "os-version".
    function: []const u8,
    // The function's input as JSON, laid out as the function takes it (see `NativeAppFunction`).
    input: std.json.Value,
};

//
// The main thread sends a worker the native app's result for one of its requests ("native-app-response").
//
pub const INativeAppResponseMessage = struct {
    // Always "native-app-response".
    type: []const u8 = "native-app-response",
    // The id of the request this is the response to.
    requestId: u64,
    // The native app's result as JSON, when it did what the request named.
    result: ?std.json.Value = null,
    // The text of the reason, when it could not.
    @"error": ?[]const u8 = null,
};

//
// The native functions a `native-app-request` names, and the input each takes.
//
pub const NativeAppFunction = struct {
    // Shows a file or folder dialog. The input is `PickPathsInput` and the result is a JSON array of the chosen paths.
    pub const pick_paths = "pick-paths";
    // Does one thing only the platform can do, by name. The input is `NativeCallInput` and the result is the JSON the native app
    // gave.
    pub const native_call = "native-call";
    // Reads the operating system's version. The input is null and the result is a JSON string.
    pub const os_version = "os-version";
};

//
// The input of a "pick-paths" request.
//
pub const PickPathsInput = struct {
    // The kind of dialog, as types.PickKind numbers it.
    kind: i32,
    // The dialog's title, or null.
    title: ?[]const u8 = null,
    // The suggested name or starting folder, or null.
    initialName: ?[]const u8 = null,
};

//
// The input of a "native-call" request.
//
pub const NativeCallInput = struct {
    // The name of what the native app is to do.
    method: []const u8,
    // The JSON text of its argument.
    request: []const u8,
};

//
// Encodes a message to JSON text allocated with the allocator. An optional field that is null is left out, as JSON.stringify
// leaves out an undefined property.
//
pub fn encode(allocator: std.mem.Allocator, message: anytype) ![]u8 {
    return json.stringify(allocator, message);
}

//
// The "type" of a message that has been parsed, or null when it is not an object with a string "type".
//
pub fn typeOf(message: std.json.Value) ?[]const u8 {
    return json.getString(message, "type");
}

//
// Parses the JSON text of a message into the struct of its type, allocated with the allocator.
//
pub fn decode(comptime T: type, allocator: std.mem.Allocator, text: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

//
// Parses a message already parsed as a JSON value into the struct of its type, allocated with the allocator.
//
pub fn decodeValue(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) !T {
    return std.json.parseFromValueLeaky(T, allocator, value, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}
