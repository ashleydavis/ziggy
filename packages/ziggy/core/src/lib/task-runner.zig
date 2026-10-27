//
// What a task handler is written against: the handler types, task priorities and kinds, the task services and the context a task is
// started with.
//
// A task runs on a worker (see worker.zig), one task at a time, and the worker keeps its own data to itself. Every task handler takes
// the same arguments: the task services, the worker's timers, the worker's Io, an allocator, the task's context and the payload. The
// task services reach everything outside the worker only by message: they send the task's events and child tasks to the main thread,
// wait on its children and check for cancel by reading the messages the main thread sends the worker, and have the native app do
// something (show a file dialog, for one) by sending the main thread a `native-app-request` and waiting for the `native-app-response`.
//

const std = @import("std");
const types = @import("types.zig");
const json = @import("json.zig");
const utils = @import("task-queue.zig").utils;
const task_queue_types = @import("task-queue.zig").types;
const worker_lib = @import("worker.zig");
const worker_messages = @import("worker-messages.zig");
const timers_lib = @import("timers.zig");

const Completion = types.Completion;
const ZiggyConfig = types.ZiggyConfig;
const Timers = timers_lib.Timers;

//
// A task handler as the worker calls it: App turns each of the app's task handlers into one, which parses the payload into the
// handler's payload type and turns its result into JSON text (allocated with the allocator), or null for none. It returns
// error.Cancelled when it stops because its task was cancelled.
//
pub const TaskHandler = *const fn (services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) anyerror!?[]const u8;

//
// How urgent a task is, as TaskPriority is in the task-queue package: interactive is something the user is waiting on, and goes ahead
// of every background task already waiting; background is everything else.
//
pub const TaskPriority = enum {
    // Something the user is waiting on.
    interactive,
    // Work that happens on its own.
    background,
};

//
// Works out what priority a child task runs at (resolveTaskPriority): one passed for it always wins, which is what lets a
// long-running child opt back down to background, and otherwise it runs at its parent's priority, so an import's children can
// never overtake something the user is waiting on.
//
pub fn resolveTaskPriority(requested: ?TaskPriority, parent_priority: TaskPriority) TaskPriority {
    if (requested) |priority| {
        return priority;
    }
    return parent_priority;
}

//
// Whether a task type keeps the app running when the app is not in the foreground. A task of a keep-alive type that is queued or
// running makes the core call the native app's keep_alive callback to keep the app running, until the last such task ends.
//
pub const TaskKind = enum {
    // An ordinary task. The platform may stop it when the app is in the background.
    normal,
    // A task the app must be kept running for, on every platform, by the means that platform has.
    keep_alive,
};

//
// A task type and its handler.
//
pub const TaskHandlerEntry = struct {
    // The task type string the frontend queues the task under.
    name: []const u8,
    // The function that runs the task.
    handler: TaskHandler,
    // Whether the app is kept running for tasks of this type. A child task takes its parent's kind.
    kind: TaskKind = .normal,
};

//
// What a task is started with: plain values, which the handler may keep for as long as the task runs.
//
pub const TaskContext = struct {
    // The id of the task.
    task_id: []const u8,
    // The task type string, for a handler that serves several types.
    task_type: []const u8,
    // The source the task was queued under.
    source: []const u8,
    // The limit on child tasks in flight for this task.
    max_concurrent_child_tasks: u32,
    // The app's private data directory.
    data_dir: []const u8,
};

//
// One child task a task has queued, as the running task keeps it.
//
const Child = struct {
    // How the child ended, once the main thread has reported it. The strings are allocated with the task's allocator.
    completion: ?Completion,
};

//
// The state of the task a worker is running, behind its TaskServices. It lives on the worker's stack for as long as the task runs, and
// is used only on the worker's thread. No handler sees it. What it keeps is allocated with the task's allocator, which each function
// that allocates is given.
//
pub const RunningTask = struct {
    // The worker running the task.
    worker: *worker_lib.WorkerRuntime,
    // The id of the task.
    task_id: []const u8,
    // The source the task was queued under.
    task_source: []const u8,
    // Set once a cancel for the task's source has been read.
    cancelled: bool,
    // The children this task has queued, by id. A child stays here until the task ends or releases it.
    children: std.StringHashMapUnmanaged(Child),
    // The number of children that have been queued and have not ended.
    inflight_children: u32,
    // The number of children queued so far, which names the next one.
    next_child: u32,

    //
    // The limit on child tasks in flight for this task.
    //
    pub fn maxConcurrentChildTasks(self: *RunningTask) u32 {
        return self.worker.options.maxConcurrentChildTasks;
    }

    //
    // Records that the main thread reported a child of this task ended, copying the completion with the task's allocator. Returns
    // false when the task has no child of that id. Called by the worker, on the worker's thread, as it reads the message.
    //
    pub fn childEnded(self: *RunningTask, allocator: std.mem.Allocator, child_id: []const u8, completion: Completion) !bool {
        const child = self.children.getPtr(child_id) orelse {
            return false;
        };
        if (child.completion != null) {
            return true;
        }
        child.completion = .{
            .status = completion.status,
            .result_json = if (completion.result_json) |text| try allocator.dupe(u8, text) else null,
            .error_message = if (completion.error_message) |text| try allocator.dupe(u8, text) else null,
        };
        self.inflight_children -= 1;
        return true;
    }

    //
    // Whether the task has a child of that id that has ended.
    //
    pub fn hasEndedChild(self: *RunningTask, child_id: []const u8) bool {
        const child = self.children.get(child_id) orelse {
            return false;
        };
        return child.completion != null;
    }

    //
    // Whether the task has a child of that id, ended or not.
    //
    pub fn hasChild(self: *RunningTask, child_id: []const u8) bool {
        return self.children.contains(child_id);
    }

    //
    // Waits for every child to end.
    //
    pub fn awaitAllTasks(self: *RunningTask, io: std.Io, allocator: std.mem.Allocator, timers: Timers) void {
        self.worker.waitFor(io, allocator, timers, .all_children);
    }

    //
    // Whether the task's source has been cancelled. It reads the messages already waiting for the worker, without waiting for more.
    //
    pub fn isCancelled(self: *RunningTask, io: std.Io, allocator: std.mem.Allocator) bool {
        self.worker.look(io, allocator);
        return self.cancelled;
    }

    //
    // Sends any value std.json can serialise to the frontend as the data of a task-event event.
    //
    pub fn sendEvent(self: *RunningTask, io: std.Io, allocator: std.mem.Allocator, value: anytype) !void {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        try self.worker.parentPort().postMessage(io, try json.stringify(arena, .{
            .type = "task-message",
            .taskId = self.task_id,
            .message = json.Raw{
                .text = try json.stringify(arena, value),
            },
        }));
    }

    //
    // Has the native app do one thing only the platform can do (see TaskServices.nativeCall).
    //
    pub fn nativeCall(self: *RunningTask, io: std.Io, allocator: std.mem.Allocator, timers: ?Timers, method: []const u8, request_json: []const u8) !types.NativeCallResult {
        if (!self.worker.options.hasNativeCall) {
            return error.NativeCallMissing;
        }
        const response = try self.worker.nativeRequest(io, allocator, timers, worker_messages.NativeAppFunction.native_call, worker_messages.NativeCallInput{
            .method = method,
            .request = request_json,
        });
        return switch (response) {
            .result => |text| .{
                .succeeded = true,
                .text = text,
            },
            .failure => |text| failed: {
                if (std.mem.eql(u8, text, "NativeCallMissing")) {
                    return error.NativeCallMissing;
                }
                break :failed .{
                    .succeeded = false,
                    .text = text,
                };
            },
        };
    }
};

//
// What a task handler reaches outside its worker through: an interface whose calls the worker turns into JSON messages to the main
// thread. It is a small value that may be copied, and it is valid on the task's worker for as long as the task runs. Each call is given
// the Io, the allocator and the timers the handler was given: the allocator is the task's, which what a call gives back is allocated
// with, and the timers run while a call waits.
//
pub const TaskServices = struct {
    // The task behind the interface.
    task: *RunningTask,
    // The worker's log, which sends each line to the main thread, where it is written tagged with the worker.
    log: utils.log.ILog,

    //
    // Whether the task's source has been cancelled. It reads the messages already waiting for the worker, without waiting for more.
    //
    pub fn isCancelled(self: TaskServices, io: std.Io, allocator: std.mem.Allocator) bool {
        return self.task.isCancelled(io, allocator);
    }

    //
    // Returns error.Cancelled when the task's source has been cancelled.
    //
    pub fn checkCancelled(self: TaskServices, io: std.Io, allocator: std.mem.Allocator) !void {
        if (self.isCancelled(io, allocator)) {
            return error.Cancelled;
        }
    }

    //
    // Waits until the task's source is cancelled, for a task whose own work runs elsewhere until then. The timers given run as they
    // come due while it waits.
    //
    pub fn waitUntilCancelled(self: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers) void {
        self.task.worker.waitFor(io, allocator, timers, .cancelled);
    }

    //
    // Sends any value std.json can serialise to the frontend as the data of a task-event event.
    //
    pub fn sendEvent(self: TaskServices, io: std.Io, allocator: std.mem.Allocator, value: anytype) !void {
        try self.task.sendEvent(io, allocator, value);
    }

    //
    // Queues a child task and returns its id, allocated with the task's allocator. The child runs at the priority passed, or at this
    // task's when none is passed. Waits while the limit on child tasks in flight is reached. Returns error.Cancelled when this task has
    // been cancelled.
    //
    pub fn queueChild(self: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, task_type: []const u8, data: anytype, priority: ?TaskPriority) ![]const u8 {
        const data_json = try json.stringify(allocator, data);
        return try self.queueChildJson(io, allocator, timers, allocator, task_type, data_json, priority);
    }

    //
    // Waits for one child to end and returns how it ended, with the strings allocated with the task's allocator. A failed child is
    // returned as a failure, never hidden.
    //
    pub fn awaitTask(self: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, child_id: []const u8) !Completion {
        return try self.awaitChild(io, allocator, timers, allocator, child_id);
    }

    //
    // Runs one child task to its end and returns how it ended, with everything this call held for it released. Unlike queueChild and
    // awaitTask it keeps nothing of the child once it returns: the data and the child's id are written with `scratch`, the completion
    // is copied with it, and the child is forgotten before this returns. It is for a task that runs children one after another for as
    // long as it lives. Returns error.Cancelled when this task has been cancelled.
    //
    pub fn runChild(self: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, scratch: std.mem.Allocator, task_type: []const u8, data: anytype, priority: ?TaskPriority) !Completion {
        const data_json = try json.stringify(scratch, data);
        const child_id = try self.queueChildJson(io, allocator, timers, scratch, task_type, data_json, priority);
        defer self.releaseChild(child_id);
        return try self.awaitChild(io, allocator, timers, scratch, child_id);
    }

    //
    // Has the native app do one thing only the platform can do, by name, with the JSON text of the argument, and returns what it gave
    // (see NativeCallFn), allocated with the task's allocator. The call goes to the main thread, which calls the native app, and
    // this waits for its result. A platform with no such callback gives error.NativeCallMissing, and one that cannot do what the
    // method names gives a result that did not succeed, with the reason in its text.
    //
    pub fn nativeCall(self: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: ?Timers, method: []const u8, request_json: []const u8) !types.NativeCallResult {
        return try self.task.nativeCall(io, allocator, timers, method, request_json);
    }

    //
    // The native caller that hands the native calls of this task to code that does not know about tasks, or null when the native app
    // gave the core no native call callback (every desktop). The storage is the caller's, and the native caller is valid as long as
    // it and this task are. Its calls run none of the task's timers while they wait.
    //
    pub fn nativeCaller(self: TaskServices, storage: *TaskNativeCaller) ?utils.native_caller.INativeCaller {
        if (!self.task.worker.options.hasNativeCall) {
            return null;
        }
        storage.* = .{
            .task = self.task,
        };
        return .{
            .ptr = storage,
            .request = TaskNativeCaller.request,
        };
    }

    //
    // Shows a native file or folder dialog and returns what the user chose as the JSON text of an array of path strings, empty when
    // they cancelled, allocated with the task's allocator. The call goes to the main thread, which has the native app show the
    // dialog, and this waits for the user.
    //
    pub fn pickPaths(self: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, kind: types.PickKind, title: ?[]const u8, initial_name: ?[]const u8) ![]const u8 {
        const response = try self.task.worker.nativeRequest(io, allocator, timers, worker_messages.NativeAppFunction.pick_paths, worker_messages.PickPathsInput{
            .kind = @intFromEnum(kind),
            .title = title,
            .initialName = initial_name,
        });
        return switch (response) {
            .result => |text| text,
            .failure => |text| if (std.mem.eql(u8, text, "NativeCallMissing")) error.NativeCallMissing else error.NativeCallFailed,
        };
    }

    //
    // Reads the operating system's version, as the JSON text of a string allocated with the task's allocator, through the native app's
    // os_version callback. The call goes to the main thread, which calls the native app, and this waits for its result.
    //
    pub fn osVersion(self: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers) ![]const u8 {
        if (!self.task.worker.options.hasOsVersion) {
            return error.NativeCallMissing;
        }
        const response = try self.task.worker.nativeRequest(io, allocator, timers, worker_messages.NativeAppFunction.os_version, null);
        return switch (response) {
            .result => |text| text,
            .failure => error.NativeCallFailed,
        };
    }

    //
    // Queues a child whose data is JSON text already, and returns its id, allocated with `id_allocator`. The task's table of children
    // is allocated with the task's allocator.
    //
    fn queueChildJson(self: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, id_allocator: std.mem.Allocator, task_type: []const u8, data_json: []const u8, priority: ?TaskPriority) ![]const u8 {
        const task = self.task;
        if (self.isCancelled(io, allocator)) {
            return error.Cancelled;
        }
        if (task.inflight_children >= task.maxConcurrentChildTasks()) {
            task.worker.waitFor(io, allocator, timers, .child_slot);
        }
        if (task.cancelled) {
            return error.Cancelled;
        }
        const child_id = try std.fmt.allocPrint(id_allocator, "{s}.c{d}", .{ task.task_id, task.next_child });
        try task.children.put(allocator, child_id, .{
            .completion = null,
        });
        errdefer _ = task.children.remove(child_id);
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        try task.worker.parentPort().postMessage(io, try json.stringify(arena_state.allocator(), .{
            .type = "queue-task",
            .taskId = child_id,
            .taskType = task_type,
            .data = json.Raw{
                .text = data_json,
            },
            .source = task.task_source,
            .priority = if (priority) |given| switch (given) {
                .interactive => "interactive",
                .background => "background",
            } else null,
        }));
        task.next_child += 1;
        task.inflight_children += 1;
        return child_id;
    }

    //
    // Waits for a child to end and returns its completion, with the strings copied with `copy_allocator`.
    //
    fn awaitChild(self: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, copy_allocator: std.mem.Allocator, child_id: []const u8) !Completion {
        const task = self.task;
        if (!task.children.contains(child_id)) {
            return error.UnknownChildTask;
        }
        task.worker.waitFor(io, allocator, timers, .{
            .child = child_id,
        });
        const completion = task.children.get(child_id).?.completion.?;
        return .{
            .status = completion.status,
            .result_json = if (completion.result_json) |text| try copy_allocator.dupe(u8, text) else null,
            .error_message = if (completion.error_message) |text| try copy_allocator.dupe(u8, text) else null,
        };
    }

    //
    // Forgets a child that has ended. Its id is not valid afterwards.
    //
    fn releaseChild(self: TaskServices, child_id: []const u8) void {
        const removed = self.task.children.fetchRemove(child_id) orelse {
            std.debug.panic("releaseChild: {s} is not a child of {s}", .{ child_id, self.task.task_id });
        };
        std.debug.assert(removed.value.completion != null);
    }
};

//
// Wraps a task handler in the function the worker calls. `label` names the handler in a compile error, such as
// `the task type "hello-world-task"`. A task handler is
//
//   fn (services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator,
//       context: ziggy.task_runner.TaskContext, payload: Payload) !Result
//
// Payload is the type the task's data is parsed into, as a message's data is for a message handler (see handlers.zig): a struct, any
// type std.json can parse into, or std.json.Value for the data unparsed. Result is turned into the JSON of the task's result, and void
// is a task with no result. The allocator is freed when the task ends, and the result is copied before then.
//
pub fn wrapTask(comptime label: []const u8, comptime handler: anytype) TaskHandler {
    const Handler = @TypeOf(handler);
    const form = "fn (services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, payload: YourPayload) !YourResult";
    if (@typeInfo(Handler) != .@"fn") {
        @compileError("ziggy.core: the handler of " ++ label ++ " is not a function. A task handler is " ++ form ++ ".");
    }
    const info = @typeInfo(Handler).@"fn";
    if (info.params.len != 6 or info.params[0].type != TaskServices or info.params[1].type != Timers or info.params[2].type != std.Io or info.params[3].type != std.mem.Allocator or info.params[4].type != TaskContext or info.params[5].type == null) {
        @compileError("ziggy.core: the handler of " ++ label ++ " has the wrong parameters. A task handler is " ++ form ++ ".");
    }
    const Payload = info.params[5].type.?;
    const Return = info.return_type orelse {
        @compileError("ziggy.core: the handler of " ++ label ++ " must name its return type.");
    };
    const returns_error = @typeInfo(Return) == .error_union;
    const Result = if (returns_error) @typeInfo(Return).error_union.payload else Return;
    return &struct {
        fn run(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
            const payload: Payload = if (Payload == std.json.Value) data else try std.json.parseFromValueLeaky(Payload, allocator, if (data == .null and @typeInfo(Payload) == .@"struct") .{
                .object = .empty,
            } else data, .{
                .ignore_unknown_fields = true,
            });
            const result = if (returns_error) try handler(services, timers, io, allocator, context, payload) else handler(services, timers, io, allocator, context, payload);
            if (Result == void) {
                return null;
            }
            return try json.stringify(allocator, result);
        }
    }.run;
}

//
// Turns a handler written against the task queue package (a TaskHandler of that package, which takes an ITaskContext and returns its
// outputs as a JSON value) into a task handler, so an app lists it in its `.tasks` like any other.
//
pub fn fromQueueHandler(comptime handler: task_queue_types.TaskHandler) TaskHandler {
    return &struct {
        fn run(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
            return try runQueueHandler(services, timers, io, allocator, context, handler, data);
        }
    }.run;
}

//
// Runs a handler written against the task queue package in a task, with an ITaskContext that reaches the task's services, and returns
// its outputs as JSON text allocated with the allocator.
//
pub fn runQueueHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, handler: task_queue_types.TaskHandler, data: std.json.Value) anyerror!?[]const u8 {
    var native_caller_storage: TaskNativeCaller = undefined;
    const worker = services.task.worker;
    const task_context: task_queue_types.ITaskContext = .{
        .uuidGenerator = worker.uuid_generator,
        .timestampProvider = worker.timestamp_provider,
        .sessionId = worker.session_id,
        .taskId = context.task_id,
        .maxConcurrentChildTasks = context.max_concurrent_child_tasks,
        .nativeCaller = services.nativeCaller(&native_caller_storage),
        .ptr = services.task,
        .vtable = &queue_context_vtable,
    };
    const outputs = try handler(allocator, io, timers, services.log, data, task_context);
    return try std.json.Stringify.valueAlloc(allocator, outputs, .{});
}

//
// The functions of the ITaskContext of a handler written against the task queue package, which reach the task it runs in.
//
const queue_context_vtable: task_queue_types.ITaskContext.VTable = .{
    .sendEvent = queueContextSendEvent,
    .isCancelled = queueContextIsCancelled,
};

//
// Sends an event to the frontend and to the observers, writing to the log when it cannot.
//
fn queueContextSendEvent(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, log: utils.log.ILog, event: std.json.Value) void {
    const task: *RunningTask = @ptrCast(@alignCast(ptr));
    task.sendEvent(io, allocator, event) catch |err| {
        log.exception("Error sending a task event", err);
    };
}

//
// Whether the task's source has been cancelled.
//
fn queueContextIsCancelled(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) bool {
    const task: *RunningTask = @ptrCast(@alignCast(ptr));
    return task.isCancelled(io, allocator);
}

//
// What a task's native caller calls: the native app's native call callback, through the task. A result that did not
// succeed is an error with the native app's reason in it.
//
pub const TaskNativeCaller = struct {
    // The task whose native calls are made.
    task: *RunningTask,

    //
    // Has the native app do what the method names and returns its result, allocated with the allocator.
    //
    fn request(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) anyerror![]const u8 {
        const self: *TaskNativeCaller = @ptrCast(@alignCast(ptr));
        const reply = try self.task.nativeCall(io, allocator, null, method, request_json);
        if (!reply.succeeded) {
            return utils.errors.throwError("{s} failed: {s}", .{ method, reply.text });
        }
        return reply.text;
    }
};

//
// The services of the running task a timer's callback on a worker is given, as its `services` (see `ziggy.timers.TimerCallback`).
//
pub fn taskServicesOf(services: ?*const anyopaque) TaskServices {
    const given: *const TaskServices = @ptrCast(@alignCast(services orelse {
        @panic("a timer's callback on a worker was given no task services");
    }));
    return given.*;
}
