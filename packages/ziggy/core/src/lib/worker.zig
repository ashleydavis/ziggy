//
// A worker: a thread that runs one task at a time and keeps its own data to itself. It is the counterpart of a TypeScript worker
// (worker.ts), and talks to the main thread only by JSON messages (see worker-messages.zig).
//
// The main side is `Worker`: the main thread starts one, sends it messages with `postMessage` and gets the worker's messages through
// its `onmessage`. The worker side is `initWorker`, the function the worker's thread runs: it sends "worker-ready", then reads its
// messages and runs each task it is sent with `executeTask`, sending the main thread what the task does through `parentPort`.
//

const std = @import("std");
const types = @import("types.zig");
const json = @import("json.zig");
const message_queue = @import("message-queue.zig");
const worker_messages = @import("worker-messages.zig");
const task_runner = @import("task-runner.zig");
const task_queue = @import("task-queue.zig");

const MessageQueue = message_queue.MessageQueue;
const Message = message_queue.Message;
const RunningTask = task_runner.RunningTask;
const TaskHandlerEntry = task_runner.TaskHandlerEntry;
const Completion = types.Completion;
const utils = task_queue.utils;
const WorkerQueueBackend = task_queue.worker_queue_backend.WorkerQueueBackend;
const QueueLog = @import("thread-log.zig").QueueLog;
const ThreadAllocator = @import("thread-allocator.zig").ThreadAllocator;
const timers_lib = @import("timers.zig");

//
// The options a worker is started with, which the main thread sends it as JSON text when it starts it (a TypeScript worker is
// given IWorkerOptions in the WORKER_OPTIONS environment variable).
//
pub const IWorkerOptions = struct {
    // Numbers the worker among the workers of its pool, and names it in the messages it sends.
    workerId: u32,
    // When true, verbose log lines are sent to the main thread.
    verbose: bool = false,
    // When true, the output of the tools a task runs is sent to the main thread.
    tools: bool = false,
    // Identifies this run of the app to the handlers. Empty for the worker to make one, as TypeScript does when it is not given.
    sessionId: []const u8 = "",
    // How many child tasks one task may have running at once.
    maxConcurrentChildTasks: u32,
    // Whether the native app has a native call callback, so a task's native calls are sent to the main thread.
    hasNativeCall: bool = false,
    // Whether the native app has an os_version callback.
    hasOsVersion: bool = false,
    // The app's private data directory.
    dataDir: []const u8 = "",
    // A copy of the environment of the thread that started the worker, as a JSON object of names and values, which the worker sets as
    // its own (see process-env.zig), or null when that thread had none.
    environment: ?std.json.Value = null,
};

//
// Makes an environment from the JSON object of names and values in a worker's options or the main thread's start message, allocated
// with the allocator.
//
pub fn environmentFromJson(allocator: std.mem.Allocator, value: std.json.Value) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    if (value != .object) {
        return error.EnvironmentIsNotAnObject;
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) {
            return error.EnvironmentValueIsNotAString;
        }
        try map.put(entry.key_ptr.*, entry.value_ptr.string);
    }
    return map;
}

//
// The JSON object of names and values of an environment, as the options of a worker and the main thread's start message carry it.
//
pub fn environmentJson(allocator: std.mem.Allocator, map: *const std.process.Environ.Map) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        try object.put(allocator, entry.key_ptr.*, .{
            .string = entry.value_ptr.*,
        });
    }
    return .{
        .object = object,
    };
}

//
// What the main thread gives a worker when it starts it: the options as JSON text, which reach the worker as a message, and the app's task types
// and functions, which are constants of the app's code and never change.
//
pub const WorkerSetup = struct {
    // The worker's options (IWorkerOptions) as JSON text. `Worker.start` posts a copy to the worker's queue as its first message.
    options_json: []const u8,
    // The app's task types.
    tasks: []const TaskHandlerEntry,
    // Gives the text to report for the error a task handler returned, or null to report the error's name.
    describe_error: ?types.ErrorDescriber,
};

//
// The main side's handler for the messages a worker sends, as `worker.on('message', ...)` is in TypeScript. It is called on the thread
// that reads the main thread's queue, and the text is valid only during the call.
//
pub const OnMessage = struct {
    // The handler's own pointer, passed back on every call.
    context: ?*anyopaque,
    // Handles one message from the worker, with the main thread's Io, allocator and timers.
    function: *const fn (context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, worker: *Worker, text: []const u8) void,
};

//
// The main side of a worker: the thread and the queue its messages from the main thread wait in. It is allocated with the main thread's
// allocator, which `start` and `destroy` are given. The worker's thread never uses it: it makes an allocator of its own.
//
pub const Worker = struct {
    // Numbers the worker among the workers of its pool. The worker's messages reach the main thread's queue under this number.
    id: u32,
    // The messages from the main thread the worker has not read yet. The worker's thread reads it, and only the main thread posts
    // to it.
    queue: MessageQueue,
    // The worker's thread.
    thread: std.Thread,
    // The main side's handler for the worker's messages, or null when nothing handles them yet.
    onmessage: ?OnMessage,

    //
    // Starts a worker whose messages go to the main thread's queue, numbered with the id given. `io` is the calling thread's, the main
    // thread's, which this side of the worker posts with.
    //
    pub fn start(allocator: std.mem.Allocator, io: std.Io, id: u32, main_queue: *MessageQueue, setup: WorkerSetup) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        self.* = .{
            .id = id,
            .queue = MessageQueue.init(),
            .thread = undefined,
            .onmessage = null,
        };
        errdefer self.queue.deinit();
        // The worker's options are the first message in its queue, which it takes with its own allocator.
        try self.queue.post(io, 0, setup.options_json);
        self.thread = try std.Thread.spawn(.{}, initWorker, .{ &self.queue, main_queue, id, setup.tasks, setup.describe_error });
        return self;
    }

    //
    // Sends the worker a message, a copy of the JSON text.
    //
    pub fn postMessage(self: *Worker, io: std.Io, text: []const u8) !void {
        try self.queue.post(io, 0, text);
    }

    //
    // Hands a message the worker sent to the main side's handler. The main thread calls it for each message it takes from its queue
    // under this worker's id.
    //
    pub fn receive(self: *Worker, io: std.Io, allocator: std.mem.Allocator, timers: Timers, text: []const u8) void {
        const handler = self.onmessage orelse {
            return;
        };
        handler.function(handler.context, io, allocator, timers, self, text);
    }

    //
    // Waits for the worker's thread to end, then releases the worker with the main thread's allocator, which `start` allocated it with.
    // The worker must have been sent "shutdown".
    //
    pub fn destroy(self: *Worker, allocator: std.mem.Allocator) void {
        self.thread.join();
        self.queue.deinit();
        allocator.destroy(self);
    }

    //
    // Lets the worker's thread go without waiting for it, for a worker whose task will not end, as `worker.terminate()` is used in
    // TypeScript. A thread cannot be stopped from outside it, so it goes on running: whatever it still sends reaches the main thread
    // under its id, which the pool no longer knows. The worker's memory is never freed, because the thread may still use it.
    //
    pub fn abandon(self: *Worker) void {
        self.thread.detach();
    }
};

//
// How the worker sends the main thread a message, as `parentPort.postMessage` is in TypeScript.
//
pub const ParentPort = struct {
    // The main thread's queue.
    main_queue: *MessageQueue,
    // The worker's id, which the message carries.
    worker_id: u32,

    //
    // Sends the main thread a copy of the JSON text.
    //
    pub fn postMessage(self: ParentPort, io: std.Io, text: []const u8) !void {
        try self.main_queue.post(io, self.worker_id, text);
    }
};

//
// What a task waits for (see `WorkerRuntime.waitFor`).
//
pub const WaitTarget = union(enum) {
    // One child of the running task to end, by id.
    child: []const u8,
    // A place under the running task's child task limit.
    child_slot,
    // Every child of the running task to end.
    all_children,
    // The response to a request to the native app, by request id.
    native_response: u64,
};

//
// What the native app gave for a request: its result as text, or the reason it could not.
//
pub const NativeResponse = union(enum) {
    // The text the native app gave.
    result: []const u8,
    // The reason it could not do what the request named.
    failure: []const u8,
};

//
// The worker side: everything the worker's thread keeps while it runs. It lives on the thread's stack. It holds no Io, allocator or
// timers: the worker's thread makes its own and passes them to each function. The allocator a function is given owns the messages
// the worker keeps: the worker's own allocator between tasks, and the running task's allocator while a task runs (see
// `executeTask`, which moves the kept messages from one to the other when a task starts and ends).
//
pub const WorkerRuntime = struct {
    // The worker's options, parsed from the JSON text the main thread gave it, in memory the worker owns.
    options: IWorkerOptions,
    // The messages from the main thread.
    queue: *MessageQueue,
    // The main thread's queue and the worker's id.
    port: ParentPort,
    // The app's task types.
    tasks: []const TaskHandlerEntry,
    // Gives the text to report for the error a task handler returned, or null.
    describe_error: ?types.ErrorDescriber,
    // Messages read while a task waited for another message, kept in the order they arrived until the task next looks.
    kept: std.ArrayList(Message),
    // The task being run, or null between tasks.
    current: ?*RunningTask,
    // Set once "shutdown" has been read while a task ran, so the worker ends when the task does.
    shutdown_requested: bool,
    // The id of the next request to the native app.
    next_request_id: u64,
    // The responses to requests to the native app that have arrived, by request id, as the text of the message. A request is made
    // only while a task runs and its response is read before the request returns, so this is empty between tasks.
    native_responses: std.AutoHashMapUnmanaged(u64, Message),
    // Sends a task's child tasks queued through the task queue package to the main thread, and tells that package's queues when they end.
    backend: WorkerQueueBackend,
    // Makes the ids of the tasks the task queue package queues: the test generator when NODE_ENV is "testing", as in TypeScript, and a
    // random one otherwise.
    uuid_generator: utils.uuid_generator.IUuidGenerator,
    // Makes the time stamps of the task queue package's contexts: the test provider when NODE_ENV is "testing", as in TypeScript.
    timestamp_provider: utils.timestamp_provider.ITimestampProvider,
    // Identifies this run of the app to the handlers: the session id of the options, or one the worker made when they have none.
    session_id: []const u8,

    //
    // How the worker sends the main thread a message.
    //
    pub fn parentPort(self: *WorkerRuntime) ParentPort {
        return self.port;
    }

    //
    // Keeps every message waiting in the queue, without waiting for more, and marks the running task cancelled when one of the kept
    // messages cancels its source. This is how a task looks for a cancel. It reads nothing else: the kept messages are read at the
    // task's next wait, which has the timers their callbacks are given, as a callback runs only at an `await` in TypeScript.
    //
    pub fn look(self: *WorkerRuntime, io: std.Io, allocator: std.mem.Allocator) void {
        while (self.queue.tryTake(io, allocator)) |message| {
            self.kept.append(allocator, message) catch @panic("out of memory keeping a message");
        }
        const context = self.current orelse {
            return;
        };
        for (self.kept.items) |message| {
            if (cancelsSource(allocator, message, context.task_source)) {
                context.cancelled = true;
            }
        }
    }

    //
    // Reads one message, a kept one first, and waits for one when there is none. The task queue package waits with it for the tasks
    // it queued.
    //
    pub fn handleNext(self: *WorkerRuntime, io: std.Io, allocator: std.mem.Allocator, timers: Timers) void {
        if (self.kept.items.len > 0) {
            const message = self.kept.orderedRemove(0);
            self.handleDuringTask(io, allocator, timers, message);
            return;
        }
        // A timer that comes due while it waits ends the wait, as a turn of JavaScript's event loop runs a timer as well as a message.
        if (self.takeOrTimeout(io, allocator, timers)) |message| {
            self.handleDuringTask(io, allocator, timers, message);
        }
        const services: task_runner.TaskServices = .{
            .task = self.current.?,
        };
        timers.runDue(io, allocator, &services);
    }

    //
    // Takes the worker's next message, waiting no longer than until the next of the timers given is due, or for as long as it takes
    // when none are given. Null when a timer came due first.
    //
    fn takeOrTimeout(self: *WorkerRuntime, io: std.Io, allocator: std.mem.Allocator, timers: ?Timers) ?Message {
        const timeout: std.Io.Timeout = if (timers) |given| given.nextTimeout() else .none;
        return self.queue.take(io, allocator, timeout) orelse {
            if (self.queue.isClosed(io)) {
                @panic("the worker's queue closed while a task waited for a message");
            }
            return null;
        };
    }

    //
    // Waits until the target is met. A message that meets it is read at once. Any other message that arrives meanwhile (another
    // child's end, a cancel) is kept in the order it arrived and read when the task next looks. The timers given run as they come
    // due while it waits. A wait given no timers runs none, and the timers that came due run at the task's next wait that has them.
    //
    pub fn waitFor(self: *WorkerRuntime, io: std.Io, allocator: std.mem.Allocator, timers: ?Timers, target: WaitTarget) void {
        while (!self.met(target)) {
            if (self.findKept(allocator, target)) |index| {
                const message = self.kept.orderedRemove(index);
                self.handleDuringTask(io, allocator, timers, message);
                continue;
            }
            const message = self.takeOrTimeout(io, allocator, timers) orelse {
                const services: task_runner.TaskServices = .{
                    .task = self.current.?,
                };
                timers.?.runDue(io, allocator, &services);
                continue;
            };
            if (self.meets(allocator, message, target)) {
                self.handleDuringTask(io, allocator, timers, message);
            }
            else {
                self.kept.append(allocator, message) catch @panic("out of memory keeping a message");
            }
        }
    }

    //
    // Sends the main thread a request for the native app to call a function with the input, waits for its response and returns
    // it, with the text allocated with the allocator, which is the running task's. The timers given run while it waits.
    //
    pub fn nativeRequest(self: *WorkerRuntime, io: std.Io, allocator: std.mem.Allocator, timers: ?Timers, function: []const u8, input: anytype) !NativeResponse {
        const request_id = self.next_request_id;
        self.next_request_id += 1;
        {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            try self.port.postMessage(io, try json.stringify(arena_state.allocator(), .{
                .type = "native-app-request",
                .requestId = request_id,
                .function = function,
                .input = input,
            }));
        }
        self.waitFor(io, allocator, timers, .{
            .native_response = request_id,
        });
        const message = self.native_responses.fetchRemove(request_id).?.value;
        defer allocator.free(message.text);
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const response = try worker_messages.decode(worker_messages.INativeAppResponseMessage, arena_state.allocator(), message.text);
        if (response.@"error") |reason| {
            return .{
                .failure = try allocator.dupe(u8, reason),
            };
        }
        const result = response.result orelse .null;
        if (result != .string) {
            return error.InvalidNativeAppResponse;
        }
        return .{
            .result = try allocator.dupe(u8, result.string),
        };
    }

    //
    // Whether the target is met.
    //
    fn met(self: *WorkerRuntime, target: WaitTarget) bool {
        const context = self.current orelse {
            return switch (target) {
                .native_response => |id| self.native_responses.contains(id),
                else => true,
            };
        };
        return switch (target) {
            .child => |id| context.hasEndedChild(id),
            .child_slot => context.inflight_children < context.maxConcurrentChildTasks(),
            .all_children => context.inflight_children == 0,
            .native_response => |id| self.native_responses.contains(id),
        };
    }

    //
    // Whether reading the message would meet the target, or bring it closer: the end of a child it waits for, or the response it
    // waits for.
    //
    fn meets(self: *WorkerRuntime, allocator: std.mem.Allocator, message: Message, target: WaitTarget) bool {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, message.text, .{}) catch {
            return false;
        };
        const message_type = worker_messages.typeOf(parsed) orelse {
            return false;
        };
        switch (target) {
            .native_response => |id| {
                if (!std.mem.eql(u8, message_type, "native-app-response")) {
                    return false;
                }
                const request_id = json.getInteger(parsed, "requestId") orelse {
                    return false;
                };
                return request_id == @as(i64, @intCast(id));
            },
            .child => |id| {
                if (!std.mem.eql(u8, message_type, "task-completed")) {
                    return false;
                }
                const task_id = json.getString(parsed, "taskId") orelse {
                    return false;
                };
                return std.mem.eql(u8, task_id, id);
            },
            .child_slot, .all_children => {
                if (!std.mem.eql(u8, message_type, "task-completed")) {
                    return false;
                }
                const task_id = json.getString(parsed, "taskId") orelse {
                    return false;
                };
                const context = self.current orelse {
                    return false;
                };
                return context.hasChild(task_id);
            },
        }
    }

    //
    // Whether the message is a cancel-tasks message for the source.
    //
    fn cancelsSource(allocator: std.mem.Allocator, message: Message, source: []const u8) bool {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), message.text, .{}) catch {
            return false;
        };
        const message_type = worker_messages.typeOf(parsed) orelse {
            return false;
        };
        if (!std.mem.eql(u8, message_type, "cancel-tasks")) {
            return false;
        }
        const cancelled = json.getString(parsed, "source") orelse {
            return false;
        };
        return std.mem.eql(u8, cancelled, source);
    }

    //
    // The index of the first kept message that meets the target, or null.
    //
    fn findKept(self: *WorkerRuntime, allocator: std.mem.Allocator, target: WaitTarget) ?usize {
        for (self.kept.items, 0..) |message, index| {
            if (self.meets(allocator, message, target)) {
                return index;
            }
        }
        return null;
    }

    //
    // Reads a message while a task runs, when an execute message is a mistake of the main thread's.
    //
    fn handleDuringTask(self: *WorkerRuntime, io: std.Io, allocator: std.mem.Allocator, timers: ?Timers, message: Message) void {
        if (self.handleMessage(io, allocator, timers, message)) |execute| {
            std.debug.panic("a worker running a task was sent another: {s}", .{execute.text});
        }
    }

    //
    // Reads one message from the main thread, as the worker's `onmessage` does in TypeScript, and frees it with the allocator unless
    // it is kept for later. An execute message is not read here: it is given back, for the caller to run its task.
    //
    fn handleMessage(self: *WorkerRuntime, io: std.Io, allocator: std.mem.Allocator, timers: ?Timers, message: Message) ?Message {
        var keep_text = false;
        defer if (!keep_text) allocator.free(message.text);
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, message.text, .{}) catch {
            std.debug.panic("a worker was sent a message that is not JSON: {s}", .{message.text});
        };
        const message_type = worker_messages.typeOf(parsed) orelse {
            std.debug.panic("a worker was sent a message with no type: {s}", .{message.text});
        };
        if (std.mem.eql(u8, message_type, "execute")) {
            keep_text = true;
            return message;
        }
        if (std.mem.eql(u8, message_type, "cancel-tasks")) {
            const cancel = worker_messages.decodeValue(worker_messages.IWorkerCancelTasksMessage, arena, parsed) catch |err| {
                std.debug.panic("a worker could not read a cancel-tasks message ({s}): {s}", .{ @errorName(err), message.text });
            };
            if (self.current) |context| {
                if (std.mem.eql(u8, context.task_source, cancel.source)) {
                    context.cancelled = true;
                }
            }
            self.backend.cancelTasks(io, allocator, cancel.source);
            return null;
        }
        if (std.mem.eql(u8, message_type, "task-completed")) {
            const completed = worker_messages.decodeValue(worker_messages.IWorkerTaskCompletedMessage, arena, parsed) catch |err| {
                std.debug.panic("a worker could not read a task-completed message ({s}): {s}", .{ @errorName(err), message.text });
            };
            if (self.current) |context| {
                const completion = completionOf(arena, completed.result) catch @panic("out of memory reading a task's end");
                _ = context.childEnded(allocator, completed.taskId, completion) catch @panic("out of memory recording a child's end");
            }
            // Every wait that reads a task's end has the timers: only the wait for a native call's response may have none, and it reads
            // nothing but that response (see waitFor).
            const given = timers orelse {
                std.debug.panic("a worker read a task's end in a wait given no timers: {s}", .{message.text});
            };
            self.backend.notifyTaskCompleted(io, allocator, given, completed.result) catch |err| {
                utils.log.log.exception("Error in a task completion callback", err);
            };
            return null;
        }
        if (std.mem.eql(u8, message_type, "native-app-response")) {
            const request_id = json.getInteger(parsed, "requestId") orelse {
                std.debug.panic("a native-app-response with no request id: {s}", .{message.text});
            };
            self.native_responses.put(allocator, @intCast(request_id), message) catch @panic("out of memory keeping a response");
            keep_text = true;
            return null;
        }
        if (std.mem.eql(u8, message_type, "shutdown")) {
            self.shutdown_requested = true;
            return null;
        }
        std.debug.panic("a worker was sent a message of an unknown type: {s}", .{message.text});
    }

    //
    // Runs the task of an execute message to its end on this thread and sends the main thread how it ended, as `executeTask` does
    // in TypeScript. A task never ends while one of its children is still running. The allocator is the worker's own, which the
    // message's text was taken with and is freed with. The task allocates with an arena of its own, freed when it ends: the messages
    // the worker keeps, the native call responses and the registrations of its task queues are allocated with it while it runs.
    //
    pub fn executeTask(self: *WorkerRuntime, io: std.Io, allocator: std.mem.Allocator, timer_list: *TimerList, execute: Message) void {
        defer allocator.free(execute.text);
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const message = worker_messages.decode(worker_messages.IWorkerMessage, arena, execute.text) catch |err| {
            std.debug.panic("a worker could not read an execute message ({s}): {s}", .{ @errorName(err), execute.text });
        };
        self.moveKept(allocator, arena);
        var task: RunningTask = .{
            .worker = self,
            .task_id = message.taskId,
            .task_source = message.source,
            .cancelled = false,
            .children = .empty,
            .inflight_children = 0,
            .next_child = 0,
        };
        self.current = &task;
        const timers = timer_list.interface();
        const data_json = json.stringify(arena, message.data) catch @panic("out of memory copying a task's data");
        const context: task_runner.TaskContext = .{
            .task_id = message.taskId,
            .task_type = message.taskType,
            .source = message.source,
            .max_concurrent_child_tasks = self.options.maxConcurrentChildTasks,
            .data_dir = self.options.dataDir,
        };
        const completion = self.callHandler(io, arena, timers, &task, context, message.data);
        task.awaitAllTasks(io, arena, timers);
        self.port.postMessage(io, taskCompletedJson(arena, message.taskId, message.taskType, data_json, completion) catch @panic("out of memory reporting a task's end")) catch @panic("out of memory reporting a task's end");
        self.current = null;
        // What the task allocated is freed with its arena, so nothing the worker keeps may point into it after: a timer the task set
        // and did not clear holds pointers into the task, so it never runs, the registrations of its task queues are forgotten and
        // the messages kept while it ran are moved back to the worker's allocator.
        timer_list.clearAll();
        self.backend.forgetAll();
        std.debug.assert(self.native_responses.count() == 0);
        self.native_responses = .empty;
        self.moveKept(arena, allocator);
    }

    //
    // Moves the kept messages and the list that holds them from one allocator to the other.
    //
    fn moveKept(self: *WorkerRuntime, from: std.mem.Allocator, to: std.mem.Allocator) void {
        var moved: std.ArrayList(Message) = .empty;
        moved.ensureTotalCapacityPrecise(to, self.kept.items.len) catch @panic("out of memory moving the kept messages");
        for (self.kept.items) |message| {
            moved.appendAssumeCapacity(.{
                .from = message.from,
                .text = to.dupe(u8, message.text) catch @panic("out of memory moving the kept messages"),
                .reply_to = message.reply_to,
            });
            from.free(message.text);
        }
        self.kept.deinit(from);
        self.kept = moved;
    }

    //
    // Finds the handler for the task's type and runs it with the standard arguments, giving the task's completion. An unknown type
    // fails the task.
    //
    fn callHandler(self: *WorkerRuntime, io: std.Io, allocator: std.mem.Allocator, timers: Timers, task: *RunningTask, context: task_runner.TaskContext, data: std.json.Value) Completion {
        var handler: ?task_runner.TaskHandler = null;
        for (self.tasks) |entry| {
            if (std.mem.eql(u8, entry.name, context.task_type)) {
                handler = entry.handler;
                break;
            }
        }
        const found = handler orelse {
            return .{
                .status = .failed,
                .result_json = null,
                .error_message = "UnknownTaskType",
            };
        };
        const services: task_runner.TaskServices = .{
            .task = task,
        };
        const result = found(services, timers, io, allocator, context, data) catch |err| {
            if (err == error.Cancelled) {
                return .{
                    .status = .cancelled,
                    .result_json = null,
                    .error_message = null,
                };
            }
            return .{
                .status = .failed,
                .result_json = null,
                .error_message = if (self.describe_error) |describe| (describe(err) orelse @errorName(err)) else @errorName(err),
            };
        };
        return .{
            .status = .succeeded,
            .result_json = result,
            .error_message = null,
        };
    }

    //
    // Reads messages between tasks until "shutdown", as the worker's `onmessage` does in TypeScript, and runs the task of each
    // execute message. The allocator is the worker's own, and the timers are the ones its tasks set.
    //
    fn run(self: *WorkerRuntime, io: std.Io, allocator: std.mem.Allocator, timer_list: *TimerList) void {
        while (!self.shutdown_requested) {
            const message = if (self.kept.items.len > 0) self.kept.orderedRemove(0) else self.queue.take(io, allocator, .none) orelse {
                return;
            };
            if (self.handleMessage(io, allocator, timer_list.interface(), message)) |execute| {
                self.executeTask(io, allocator, timer_list, execute);
            }
        }
    }
};

//
// The worker's timers, which its tasks set. Their callbacks run while the running task waits for a message.
//
const TimerList = timers_lib.TimerList;
const Timers = timers_lib.Timers;

//
// The function a worker's thread runs, as `initWorker` is in TypeScript: sets the worker up from its options, sends the main thread
// "worker-ready" and reads its messages until it is sent "shutdown".
//
fn initWorker(queue: *MessageQueue, main_queue: *MessageQueue, id: u32, tasks: []const TaskHandlerEntry, describe_error: ?types.ErrorDescriber) void {
    // The worker's own allocator, which everything on its thread is allocated with.
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    // The worker's own Io, which its tasks sleep and use files with and which it posts to and takes from the queues with.
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();
    // The worker's own timers, which its tasks set.
    var timer_list = TimerList.init();
    // The worker's options, the first message in its queue.
    const options_message = queue.take(io, allocator, .none) orelse {
        @panic("a worker's queue closed before it was sent its options");
    };
    var options_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer options_arena_state.deinit();
    const options = worker_messages.decode(IWorkerOptions, options_arena_state.allocator(), options_message.text) catch |err| {
        std.debug.panic("a worker could not read its options ({s}): {s}", .{ @errorName(err), options_message.text });
    };
    allocator.free(options_message.text);
    var environment: ?std.process.Environ.Map = if (options.environment) |value| environmentFromJson(allocator, value) catch |err| {
        std.debug.panic("a worker could not read its environment: {s}", .{@errorName(err)});
    } else null;
    defer if (environment) |*map| map.deinit();
    utils.process_env.setEnvironMap(if (environment) |*map| map else null);
    defer utils.process_env.setEnvironMap(null);
    // Test providers are used when NODE_ENV is "testing", as in TypeScript.
    const testing = std.mem.eql(u8, utils.process_env.getEnv("NODE_ENV") orelse "", "testing");
    var random_uuids: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var test_uuids: ?utils.file_test_uuid_generator.TestUuidGenerator = if (testing) utils.file_test_uuid_generator.TestUuidGenerator.init(options_arena_state.allocator()) catch @panic("out of memory starting a worker") else null;
    var timestamps: utils.timestamp_provider.TimestampProvider = .{};
    var test_timestamps: utils.test_timestamp_provider.TestTimestampProvider = .{};
    const uuid_generator = if (test_uuids) |*generator| generator.uuidGenerator() else random_uuids.uuidGenerator();
    const timestamp_provider = if (testing) test_timestamps.timestampProvider() else timestamps.timestampProvider();
    const session_id = if (options.sessionId.len > 0) options.sessionId else uuid_generator.generate(options_arena_state.allocator(), io) catch |err| {
        reportCannotStart(options_arena_state.allocator(), io, main_queue, id, err);
        return;
    };
    var runtime: WorkerRuntime = .{
        .options = options,
        .queue = queue,
        .port = .{
            .main_queue = main_queue,
            .worker_id = id,
        },
        .tasks = tasks,
        .describe_error = describe_error,
        .kept = .empty,
        .current = null,
        .shutdown_requested = false,
        .next_request_id = 1,
        .native_responses = .empty,
        .backend = undefined,
        .uuid_generator = uuid_generator,
        .timestamp_provider = timestamp_provider,
        .session_id = session_id,
    };
    runtime.backend = WorkerQueueBackend.init(.{
        .context = &runtime,
        .function = postFromBackend,
    }, .{
        .context = &runtime,
        .function = waitFromBackend,
    }, runtime.uuid_generator);
    defer {
        for (runtime.kept.items) |message| {
            allocator.free(message.text);
        }
        runtime.kept.deinit(allocator);
        runtime.backend.deinit(allocator);
    }
    task_queue.queue_backend.setQueueBackend(runtime.backend.queueBackend());
    defer task_queue.queue_backend.setQueueBackend(null);
    // The worker's log and console lines go to the main thread, the only thread that writes stdout, stderr and log files.
    var worker_log: QueueLog = .{
        .queue = main_queue,
        .from = id,
        .verbose_enabled = options.verbose,
        .tools_enabled = options.tools,
    };
    worker_log.set();
    defer QueueLog.unset();
    runtime.port.postMessage(io, "{\"type\":\"worker-ready\"}") catch @panic("out of memory starting a worker");
    runtime.run(io, allocator, &timer_list);
}

//
// Tells the main thread a worker cannot start, and why, before its thread ends.
//
fn reportCannotStart(arena: std.mem.Allocator, io: std.Io, main_queue: *MessageQueue, id: u32, err: anyerror) void {
    const failure = worker_messages.encode(arena, worker_messages.IWorkerErrorMessage{
        .message = utils.errors.errorMessage(err),
    }) catch @panic("out of memory reporting that a worker could not start");
    main_queue.post(io, id, failure) catch @panic("out of memory reporting that a worker could not start");
}

//
// What the worker's queue backend posts with: the worker's port to the main thread.
//
fn postFromBackend(context: ?*anyopaque, io: std.Io, text: []const u8) anyerror!void {
    const runtime: *WorkerRuntime = @ptrCast(@alignCast(context.?));
    try runtime.port.postMessage(io, text);
}

//
// What the worker's queue backend waits with: reads the worker's next message.
//
fn waitFromBackend(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers) void {
    const runtime: *WorkerRuntime = @ptrCast(@alignCast(context.?));
    runtime.handleNext(io, allocator, timers);
}


//
// The completion a task-completed message's result describes. A result that failed with "Cancelled" is a task that was cancelled,
// which TaskStatus has no member for.
//
pub fn completionOf(allocator: std.mem.Allocator, result: task_queue.types.ITaskResult) !Completion {
    switch (result.status) {
        .Succeeded => {
            return .{
                .status = .succeeded,
                .result_json = if (result.outputs) |outputs| try json.stringify(allocator, outputs) else null,
                .error_message = null,
            };
        },
        else => {
            const message = result.errorMessage orelse if (result.@"error") |err| err.message else "Failed";
            if (std.mem.eql(u8, message, "Cancelled")) {
                return .{
                    .status = .cancelled,
                    .result_json = null,
                    .error_message = null,
                };
            }
            return .{
                .status = .failed,
                .result_json = null,
                .error_message = message,
            };
        },
    }
}

//
// The JSON text of the task-completed message for a task that ended, laid out as IWorkerTaskCompletedMessage. TaskStatus has no
// cancelled, so a cancelled task is reported as failed with the error message "Cancelled".
//
pub fn taskCompletedJson(allocator: std.mem.Allocator, task_id: []const u8, task_type: []const u8, data_json: []const u8, completion: Completion) ![]u8 {
    const error_message: ?[]const u8 = switch (completion.status) {
        .succeeded => null,
        .cancelled => "Cancelled",
        .failed => completion.error_message orelse "Failed",
    };
    return try json.stringify(allocator, .{
        .type = "task-completed",
        .taskId = task_id,
        .result = .{
            .taskId = task_id,
            .status = if (completion.status == .succeeded) "succeeded" else "failed",
            .@"error" = if (error_message) |text| .{
                .name = "Error",
                .message = text,
            } else null,
            .errorMessage = error_message,
            .outputs = if (completion.result_json) |text| json.Raw{
                .text = text,
            } else null,
            .type = task_type,
            .inputs = json.Raw{
                .text = data_json,
            },
        },
    });
}
