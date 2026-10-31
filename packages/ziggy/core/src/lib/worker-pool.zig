//
// The worker pool: the main thread's side of the tasks. A port of the TypeScript WorkerPoolElectronMain
// (worker-pool-electron-main.ts). It owns the task list and the state of each worker (IWorkerState), starts
// workers as tasks need them up to the limit, sends each task to an idle worker (dispatchTask, tryDispatchPending) and handles what the
// workers send back (handleWorkerMessage). Everything here runs on the thread that owns the pool, the main thread, and the workers
// reach it only by message. The pool keeps no Io, allocator, timers or log: each function is given the main thread's, and everything the
// pool keeps is allocated with the main thread's allocator.
//
// It is also an IQueueBackend, as WorkerPoolElectronMain is in TypeScript, for an owner that gives every function of the pool the same
// allocator: the mock pool of the task queue's tests. The core does not make it the main thread's backend, because the main thread's
// handlers are given an arena that is freed before the pool would be done with what they added.
//

const std = @import("std");
const types = @import("types.zig");
const json = @import("json.zig");
const message_queue = @import("message-queue.zig");
const timers_lib = @import("timers.zig");
const worker_lib = @import("worker.zig");
const worker_messages = @import("worker-messages.zig");
const task_runner = @import("task-runner.zig");
const task_queue = @import("task-queue.zig");

const MessageQueue = message_queue.MessageQueue;
const Message = message_queue.Message;
const Worker = worker_lib.Worker;
const Completion = types.Completion;
const TaskPriority = task_runner.TaskPriority;
const TaskHandlerEntry = task_runner.TaskHandlerEntry;
const utils = @import("utils");
const ziggy_log = @import("log");
const qtypes = task_queue.types;
const IQueueBackend = task_queue.queue_backend.IQueueBackend;
const ILog = ziggy_log.log.ILog;

//
// Where the pool sends the events it produces for the frontend (task-event and task-completed, and the reply to a message a task
// replies to), as JSON text.
//
pub const EventSink = struct {
    // The sink's own pointer, passed back on every call.
    user_data: ?*anyopaque,
    // Delivers one event. The text is valid only during the call.
    emit: *const fn (user_data: ?*anyopaque, io: std.Io, message: []const u8) void,
};

//
// Handles a task's request to the native app: calls the native app and sends the worker its `native-app-response`.
//
pub const NativeRequestHandler = struct {
    // The handler's own pointer, passed back on every call.
    user_data: ?*anyopaque,
    // Handles the request, the JSON text of a `native-app-request`, from the worker, with the main thread's Io and allocator.
    handle: *const fn (user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, worker: *Worker, request_json: []const u8) void,
};

//
// Writes a worker's log line, on the main thread.
//
pub const LogHandler = struct {
    // The handler's own pointer, passed back on every call.
    user_data: ?*anyopaque,
    // Writes the line, the JSON text of an IWorkerLogMessage.
    write: *const fn (user_data: ?*anyopaque, message_json: []const u8) void,
};

//
// Tells the native app whether the app must keep running for tasks.
//
pub const KeepAliveHandler = struct {
    // The handler's own pointer, passed back on every call.
    user_data: ?*anyopaque,
    // Called with true when the first keep-alive task is queued or the hold begins, and false when the last ends, with the main
    // thread's Io and allocator.
    set: *const fn (user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, keep_running: bool) void,
};

//
// What the pool is made with.
//
pub const WorkerPoolOptions = struct {
    // The most workers the pool starts.
    max_workers: u32,
    // The app's task types.
    tasks: []const TaskHandlerEntry,
    // Gives the text to report for the error a task handler returned, or null to report the error's name.
    describe_error: ?types.ErrorDescriber = null,
    // The options every worker is started with. The pool fills in each worker's id.
    worker_options: worker_lib.IWorkerOptions,
    // Where the events for the frontend go, or null for none.
    sink: ?EventSink = null,
    // When true, the pool keeps a notice of every task that ends and every event a task sends, which the owner takes with
    // `takeNotice`, after the frontend has been told.
    observe: bool = false,
    // Handles the tasks' requests to the native app, or null, in which case each one fails.
    native_request: ?NativeRequestHandler = null,
    // Writes the workers' log lines, or null to write them to the main thread's log.
    on_log: ?LogHandler = null,
    // Tells the native app to keep the app running, or null.
    keep_alive: ?KeepAliveHandler = null,
};

//
// A task that ended or an event a task sent, as the pool keeps it for its owner (see `WorkerPoolOptions.observe`). The strings are
// copies, allocated with the main thread's allocator, which `deinit` frees them with.
//
pub const Notice = union(enum) {
    // A task ended.
    task_end: types.TaskEnd,
    // A task sent an event.
    task_event: types.TaskSentEvent,

    //
    // Frees the copies.
    //
    pub fn deinit(self: Notice, allocator: std.mem.Allocator) void {
        switch (self) {
            .task_end => |end| {
                allocator.free(end.task_id);
                allocator.free(end.task_type);
                allocator.free(end.source);
                allocator.free(end.input_json);
                if (end.error_message) |text| {
                    allocator.free(text);
                }
                if (end.result_json) |text| {
                    allocator.free(text);
                }
            },
            .task_event => |sent| {
                allocator.free(sent.task_id);
                allocator.free(sent.task_type);
                allocator.free(sent.source);
                allocator.free(sent.event_json);
            },
        }
    }
};

//
// One task, queued or running, as the pool keeps it (ITask in TypeScript).
//
const PoolTask = struct {
    // The task's id.
    id: []u8,
    // The task type.
    task_type: []u8,
    // The source the task was queued under.
    source: []u8,
    // The task's input as JSON text.
    data_json: []u8,
    // How urgent the task is.
    priority: TaskPriority,
    // The id of the worker whose task queued this one, which is told when it ends, or null for a task the main thread queued.
    queued_by: ?u32,
    // For a task that responds to a message from the frontend, the JSON text of the message's id. Its end is sent as that message's
    // reply instead of a task-completed event.
    reply_id_json: ?[]u8,
    // Whether the app is kept running for this task: a task of a keep-alive type that no task queued.
    keep_alive: bool,
    // Whether the task was sent to a worker.
    started: bool,
};

//
// The state of one worker (IWorkerState in TypeScript).
//
const IWorkerState = struct {
    // The worker.
    worker: *Worker,
    // Numbers the worker.
    workerId: u32,
    // True once the worker has sent its "worker-ready" message.
    isReady: bool,
    // True when the worker is not running a task.
    isIdle: bool,
    // The task the worker is running, or null when idle.
    currentTask: ?*PoolTask,
    // The number of tasks the worker has completed (used for load balancing).
    tasksProcessed: u64,
};

//
// A callback and the key that identifies it for unsubscribing, with the source it was registered for ("" when it is not for one source).
//
fn Registration(comptime CallbackT: type) type {
    return struct {
        // Identifies the registration.
        key: usize,
        // The source the callback is for, owned by the pool.
        source: []u8,
        // The callback.
        callback: CallbackT,
    };
}

//
// The keys of the registrations of a list, copied with the allocator, which the caller frees them with. A callback may register or
// unregister callbacks while the callbacks of a list are called, so they are called by these keys rather than by their places in the
// list, as Node's EventEmitter calls the listeners it had when an event was emitted.
//
fn callbackKeys(allocator: std.mem.Allocator, list: anytype) []usize {
    const keys = allocator.alloc(usize, list.items.len) catch @panic("out of memory calling callbacks");
    for (list.items, keys) |registration, *key| {
        key.* = registration.key;
    }
    return keys;
}

//
// The registration of a list with the key, or null when it has been unregistered.
//
fn registered(list: anytype, key: usize) ?@TypeOf(list.items[0]) {
    for (list.items) |registration| {
        if (registration.key == key) {
            return registration;
        }
    }
    return null;
}

//
// The pool.
//
pub const WorkerPool = struct {
    // The queue the workers send their messages to, which the owner reads.
    main_queue: *MessageQueue,
    // What the pool was made with.
    options: WorkerPoolOptions,
    // The workers.
    workers: std.ArrayList(*IWorkerState),
    // The id of the next worker started.
    next_worker_id: u32,
    // Tasks waiting for a worker: an interactive task at the head, a background task at the end.
    pending_tasks: std.ArrayList(*PoolTask),
    // Set once shutdown has begun: nothing more is sent to the frontend and no task is started.
    is_shutting_down: bool,
    // The number of keep-alive tasks that are queued or running.
    keep_alive_count: u32,
    // Whether the app has requested, through holdKeepAlive, for the app to be kept running with or without a task.
    keep_alive_held: bool,
    // Makes the ids of the tasks the main thread queues through the IQueueBackend without one.
    uuid_generator: utils.random_uuid_generator.RandomUuidGenerator,
    // The key of the next registration.
    next_key: usize,
    // Callbacks invoked whenever any task completes.
    completion_callbacks: std.ArrayList(Registration(qtypes.WorkerTaskCompletionCallback)),
    // Callbacks invoked when a task sends an event of a specific type.
    event_callbacks: std.ArrayList(Registration(qtypes.IEventCallbackEntry)),
    // Callbacks invoked when a task sends any event.
    any_event_callbacks: std.ArrayList(Registration(qtypes.TaskEventCallback)),
    // Per-source callbacks fired when a task is added.
    task_added_callbacks: std.ArrayList(Registration(qtypes.TaskAddedCallback)),
    // Per-source callbacks fired when the tasks of a source are cancelled.
    tasks_cancelled_callbacks: std.ArrayList(Registration(qtypes.TasksCancelledCallback)),
    // The notices of tasks that ended and events tasks sent that the owner has not taken yet, in the order they happened.
    notices: std.ArrayList(Notice),

    //
    // Makes a pool whose workers send their messages to the main queue. No worker starts until a task needs one.
    //
    pub fn init(main_queue: *MessageQueue, options: WorkerPoolOptions) WorkerPool {
        return .{
            .main_queue = main_queue,
            .options = options,
            .workers = .empty,
            .next_worker_id = 1,
            .pending_tasks = .empty,
            .is_shutting_down = false,
            .keep_alive_count = 0,
            .keep_alive_held = false,
            .uuid_generator = .{},
            .next_key = 0,
            .completion_callbacks = .empty,
            .event_callbacks = .empty,
            .any_event_callbacks = .empty,
            .task_added_callbacks = .empty,
            .tasks_cancelled_callbacks = .empty,
            .notices = .empty,
        };
    }

    //
    // Reads the queue's next message and hands it to the worker that sent it, or runs the owner's timers that are due when one comes
    // due first: how an owner whose queue holds only its workers' messages (the mock pool of the task queue's tests) waits for the
    // tasks it queued, as a turn of JavaScript's event loop runs a timer as well as a message.
    //
    pub fn waitForWorkerMessage(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, timers: timers_lib.Timers, log: ILog) void {
        const message = self.main_queue.take(io, allocator, timers.nextTimeout()) orelse {
            if (self.main_queue.isClosed(io)) {
                @panic("the worker pool's queue closed while its owner waited for a worker");
            }
            timers.runDue(io, allocator, null);
            return;
        };
        defer allocator.free(message.text);
        if (!self.receive(io, allocator, timers, log, message)) {
            std.debug.panic("a message reached the worker pool from no worker of it: {s}", .{message.text});
        }
    }

    //
    // Takes the first notice the owner has not taken, or null when there is none. The caller frees it with the main thread's
    // allocator (see `Notice.deinit`).
    //
    pub fn takeNotice(self: *WorkerPool) ?Notice {
        if (self.notices.items.len == 0) {
            return null;
        }
        return self.notices.orderedRemove(0);
    }

    //
    // Adds a task to the pending queue and tries to dispatch it at once. When reply_id_json is given, the task responds to the
    // frontend's message with that id: its end is that message's reply, and no task-completed event is sent.
    //
    pub fn addTask(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, log: ILog, task_id: []const u8, task_type: []const u8, source: []const u8, data_json: []const u8, priority: TaskPriority, reply_id_json: ?[]const u8) !void {
        if (self.is_shutting_down) {
            return error.ShuttingDown;
        }
        _ = try self.addTaskWithParent(io, allocator, log, task_id, task_type, source, data_json, priority, reply_id_json, null);
    }

    //
    // Adds a task, which a worker's task queued when queued_by is given, and tries to dispatch it.
    //
    fn addTaskWithParent(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, log: ILog, task_id: []const u8, task_type: []const u8, source: []const u8, data_json: []const u8, priority: TaskPriority, reply_id_json: ?[]const u8, queued_by: ?u32) !*PoolTask {
        const task = try allocator.create(PoolTask);
        errdefer allocator.destroy(task);
        task.* = .{
            .id = try allocator.dupe(u8, task_id),
            .task_type = try allocator.dupe(u8, task_type),
            .source = try allocator.dupe(u8, source),
            .data_json = try allocator.dupe(u8, data_json),
            .priority = priority,
            .queued_by = queued_by,
            .reply_id_json = if (reply_id_json) |text| try allocator.dupe(u8, text) else null,
            .keep_alive = queued_by == null and self.kindOf(task_type) == .keep_alive,
            .started = false,
        };
        if (task.priority == .interactive) {
            try self.pending_tasks.insert(allocator, 0, task);
        }
        else {
            try self.pending_tasks.append(allocator, task);
        }
        if (task.keep_alive) {
            self.keep_alive_count += 1;
            if (self.keep_alive_count == 1 and !self.keep_alive_held) {
                self.callKeepAlive(io, allocator, true);
            }
        }
        const added_keys = callbackKeys(allocator, &self.task_added_callbacks);
        defer allocator.free(added_keys);
        for (added_keys) |key| {
            const registration = registered(&self.task_added_callbacks, key) orelse {
                continue;
            };
            if (std.mem.eql(u8, registration.source, source)) {
                registration.callback.call(allocator, log, task.id);
            }
        }
        self.tryDispatchPending(io, allocator, log);
        return task;
    }

    //
    // Holds the app running with or without a task (true), or lets it go (false). The native app is told to keep the app running when the
    // hold or the first keep-alive task begins, and to stop when the hold and the last keep-alive task have both ended.
    //
    pub fn holdKeepAlive(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, keep_running: bool) void {
        if (self.keep_alive_held == keep_running) {
            return;
        }
        self.keep_alive_held = keep_running;
        if (self.keep_alive_count == 0) {
            self.callKeepAlive(io, allocator, keep_running);
        }
    }

    //
    // The kind of a task type, normal when the type is not known (the task then fails as an unknown type).
    //
    fn kindOf(self: *WorkerPool, task_type: []const u8) task_runner.TaskKind {
        for (self.options.tasks) |entry| {
            if (std.mem.eql(u8, entry.name, task_type)) {
                return entry.kind;
            }
        }
        return .normal;
    }

    //
    // Tells the native app to keep the app running, or that it need not. Nothing is sent once shutdown has begun.
    //
    fn callKeepAlive(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, keep_running: bool) void {
        if (self.is_shutting_down) {
            return;
        }
        const handler = self.options.keep_alive orelse {
            return;
        };
        handler.set(handler.user_data, io, allocator, keep_running);
    }

    //
    // Tries to dispatch every pending task to an idle worker, in order.
    //
    fn tryDispatchPending(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, log: ILog) void {
        while (self.pending_tasks.items.len > 0) {
            if (!self.dispatchTask(io, allocator, log, self.pending_tasks.items[0])) {
                break;
            }
            _ = self.pending_tasks.orderedRemove(0);
        }
    }

    //
    // Sends a task to the idle worker that has run the fewest tasks. Returns false when no worker is idle, after starting one when
    // the pool has room for it and none is starting already.
    //
    fn dispatchTask(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, log: ILog, task: *PoolTask) bool {
        if (self.is_shutting_down) {
            return false;
        }
        var available: ?*IWorkerState = null;
        for (self.workers.items) |state| {
            if (!state.isIdle) {
                continue;
            }
            if (available == null or state.tasksProcessed < available.?.tasksProcessed) {
                available = state;
            }
        }
        const state = available orelse {
            if (self.workers.items.len < self.options.max_workers) {
                var not_ready: usize = 0;
                for (self.workers.items) |candidate| {
                    if (!candidate.isReady) {
                        not_ready += 1;
                    }
                }
                if (not_ready == 0) {
                    self.createWorker(io, allocator, log) catch |err| {
                        std.debug.panic("could not start a worker: {s}", .{@errorName(err)});
                    };
                }
            }
            return false;
        };
        state.isIdle = false;
        state.currentTask = task;
        task.started = true;
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const execute = json.stringify(arena_state.allocator(), .{
            .type = "execute",
            .taskId = task.id,
            .taskType = task.task_type,
            .data = json.Raw{
                .text = task.data_json,
            },
            .source = task.source,
        }) catch @panic("out of memory sending a task to a worker");
        state.worker.postMessage(io, execute) catch @panic("out of memory sending a task to a worker");
        return true;
    }

    //
    // Starts a worker, whose messages reach the pool through the main queue.
    //
    fn createWorker(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, log: ILog) !void {
        const id = self.next_worker_id;
        self.next_worker_id += 1;
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        var options = self.options.worker_options;
        options.workerId = id;
        // A log with a file writes every line, whatever its console shows, so when the main thread's log has one the worker sends its verbose and tool
        // lines too, and the log's console options decide what the console shows.
        if (log.logFilePath() != null) {
            options.verbose = true;
            options.tools = true;
        }
        // The worker gets a copy of this thread's environment as its own.
        if (utils.process_env.getEnvironMap()) |environment| {
            options.environment = try worker_lib.environmentJson(arena_state.allocator(), environment);
        }
        const options_json = try json.stringify(arena_state.allocator(), options);
        const worker = try Worker.start(allocator, io, id, self.main_queue, .{
            .options_json = options_json,
            .tasks = self.options.tasks,
            .describe_error = self.options.describe_error,
        });
        const state = try allocator.create(IWorkerState);
        state.* = .{
            .worker = worker,
            .workerId = id,
            .isReady = false,
            .isIdle = false,
            .currentTask = null,
            .tasksProcessed = 0,
        };
        worker.onmessage = .{
            .context = self,
            .function = onWorkerMessage,
        };
        try self.workers.append(allocator, state);
    }

    //
    // Hands a message from the main queue to the worker that sent it. Returns false when no worker of the pool sent it.
    //
    pub fn receive(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, timers: timers_lib.Timers, log: ILog, message: Message) bool {
        for (self.workers.items) |state| {
            if (state.workerId == message.from) {
                state.worker.receive(io, allocator, timers, log, message.text);
                return true;
            }
        }
        return false;
    }

    //
    // The `onmessage` of every worker.
    //
    fn onWorkerMessage(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: timers_lib.Timers, log: ILog, worker: *Worker, text: []const u8) void {
        const self: *WorkerPool = @ptrCast(@alignCast(context.?));
        for (self.workers.items) |state| {
            if (state.worker == worker) {
                self.handleWorkerMessage(io, allocator, timers, log, state, text);
                return;
            }
        }
    }

    //
    // Handles a message a worker sent (worker-ready, task-completed, task-message, log, queue-task and native-app-request).
    //
    fn handleWorkerMessage(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, timers: timers_lib.Timers, log: ILog, state: *IWorkerState, text: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
            std.debug.panic("a worker sent a message that is not JSON: {s}", .{text});
        };
        const message_type = worker_messages.typeOf(parsed) orelse {
            std.debug.panic("a worker sent a message with no type: {s}", .{text});
        };
        if (std.mem.eql(u8, message_type, "worker-ready")) {
            state.isReady = true;
            state.isIdle = true;
            self.tryDispatchPending(io, allocator, log);
            return;
        }
        if (std.mem.eql(u8, message_type, "task-completed")) {
            const completed = worker_messages.decodeValue(worker_messages.IWorkerTaskCompletedMessage, arena, parsed) catch |err| {
                std.debug.panic("could not read a worker's task-completed message ({s}): {s}", .{ @errorName(err), text });
            };
            const task = state.currentTask orelse {
                std.debug.panic("a worker that was running no task sent task-completed: {s}", .{text});
            };
            state.isIdle = true;
            state.currentTask = null;
            state.tasksProcessed += 1;
            const completion = worker_lib.completionOf(arena, completed.result) catch @panic("out of memory reading a task's end");
            self.finish(io, allocator, timers, log, task, completion);
            self.tryDispatchPending(io, allocator, log);
            return;
        }
        if (std.mem.eql(u8, message_type, "task-message")) {
            const task = state.currentTask orelse {
                std.debug.panic("a worker that was running no task sent task-message: {s}", .{text});
            };
            const message = parsed.object.get("message") orelse .null;
            const event_json = json.stringify(arena, message) catch @panic("out of memory reading a task's event");
            self.taskSentEvent(io, allocator, timers, log, task, event_json, message);
            return;
        }
        if (std.mem.eql(u8, message_type, "log")) {
            if (self.options.on_log) |handler| {
                handler.write(handler.user_data, text);
            }
            else {
                writeLog(arena, log, std.fmt.allocPrint(arena, "Worker {d}", .{state.workerId}) catch @panic("out of memory writing a log line"), text);
            }
            return;
        }
        if (std.mem.eql(u8, message_type, "console")) {
            writeConsole(arena, text);
            return;
        }
        if (std.mem.eql(u8, message_type, "queue-task")) {
            const queued = worker_messages.decodeValue(worker_messages.IWorkerQueueTaskMessage, arena, parsed) catch |err| {
                std.debug.panic("could not read a worker's queue-task message ({s}): {s}", .{ @errorName(err), text });
            };
            const parent_priority: TaskPriority = if (state.currentTask) |parent| parent.priority else .background;
            const requested: ?TaskPriority = if (queued.priority) |given| switch (given) {
                .Interactive => .interactive,
                .Background => .background,
            } else null;
            const data_json = json.stringify(arena, queued.data) catch @panic("out of memory queueing a child task");
            if (self.is_shutting_down) {
                // Nothing starts once shutdown has begun, so the child ends at once as cancelled, and its parent stops waiting for it.
                const reply = worker_lib.taskCompletedJson(arena, queued.taskId, queued.taskType, data_json, .{
                    .status = .cancelled,
                    .result_json = null,
                    .error_message = null,
                }) catch @panic("out of memory cancelling a child task");
                state.worker.postMessage(io, reply) catch @panic("out of memory cancelling a child task");
                return;
            }
            _ = self.addTaskWithParent(io, allocator, log, queued.taskId, queued.taskType, queued.source, data_json, task_runner.resolveTaskPriority(requested, parent_priority), null, state.workerId) catch @panic("out of memory queueing a child task");
            return;
        }
        if (std.mem.eql(u8, message_type, "native-app-request")) {
            if (self.options.native_request) |handler| {
                handler.handle(handler.user_data, io, allocator, state.worker, text);
                return;
            }
            const request_id = json.getInteger(parsed, "requestId") orelse 0;
            const reply = json.stringify(arena, .{
                .type = "native-app-response",
                .requestId = request_id,
                .@"error" = "NativeCallMissing",
            }) catch @panic("out of memory responding to a native app request");
            state.worker.postMessage(io, reply) catch @panic("out of memory responding to a native app request");
            return;
        }
        if (std.mem.eql(u8, message_type, "worker-error")) {
            const failure = worker_messages.decodeValue(worker_messages.IWorkerErrorMessage, arena, parsed) catch |err| {
                std.debug.panic("could not read a worker's worker-error message ({s}): {s}", .{ @errorName(err), text });
            };
            // TypeScript logs a worker that ends on its own ("exit") and treats it as crashed. This one ended as it started, so it
            // had no task: it is let go, and a worker is started for the tasks queued, as one would be in its place.
            log.@"error"(std.fmt.allocPrint(arena, "Worker {d} could not start: {s}", .{ state.workerId, failure.message }) catch @panic("out of memory logging a worker that could not start"));
            for (self.workers.items, 0..) |candidate, index| {
                if (candidate == state) {
                    _ = self.workers.orderedRemove(index);
                    break;
                }
            }
            state.worker.destroy(allocator);
            allocator.destroy(state);
            self.tryDispatchPending(io, allocator, log);
            return;
        }
        std.debug.panic("a worker sent a message of an unknown type: {s}", .{text});
    }

    //
    // A task sent an event: tells the frontend, then keeps a notice of it, then calls the IQueueBackend callbacks.
    //
    fn taskSentEvent(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, timers: timers_lib.Timers, log: ILog, task: *PoolTask, event_json: []const u8, event: std.json.Value) void {
        if (self.is_shutting_down) {
            return;
        }
        if (self.options.sink) |sink| {
            const message = json.stringify(allocator, .{
                .kind = "system",
                .name = "task-event",
                .data = .{
                    .taskId = task.id,
                    .source = task.source,
                    .data = json.Raw{
                        .text = event_json,
                    },
                },
            }) catch @panic("out of memory building a task event");
            defer allocator.free(message);
            sink.emit(sink.user_data, io, message);
        }
        if (self.options.observe) {
            self.notices.append(allocator, .{
                .task_event = .{
                    .task_id = allocator.dupe(u8, task.id) catch @panic("out of memory keeping a notice"),
                    .task_type = allocator.dupe(u8, task.task_type) catch @panic("out of memory keeping a notice"),
                    .source = allocator.dupe(u8, task.source) catch @panic("out of memory keeping a notice"),
                    .event_json = allocator.dupe(u8, event_json) catch @panic("out of memory keeping a notice"),
                },
            }) catch @panic("out of memory keeping a notice");
        }
        const event_type = qtypes.eventTypeOf(event);
        const data: qtypes.ITaskEventData = .{
            .taskId = task.id,
            .event = event,
        };
        const event_keys = callbackKeys(allocator, &self.event_callbacks);
        defer allocator.free(event_keys);
        for (event_keys) |key| {
            const registration = registered(&self.event_callbacks, key) orelse {
                continue;
            };
            const wanted = event_type orelse {
                continue;
            };
            if (!std.mem.eql(u8, wanted, registration.callback.eventType)) {
                continue;
            }
            registration.callback.callback.call(io, allocator, timers, log, data) catch |err| {
                log.exception("Error in task event callback", err);
            };
        }
        const any_event_keys = callbackKeys(allocator, &self.any_event_callbacks);
        defer allocator.free(any_event_keys);
        for (any_event_keys) |key| {
            const registration = registered(&self.any_event_callbacks, key) orelse {
                continue;
            };
            registration.callback.call(io, allocator, timers, log, data) catch |err| {
                log.exception("Error in any task event callback", err);
            };
        }
    }

    //
    // Records how a task ended: tells the frontend, keeps a notice of it, calls the IQueueBackend callbacks, tells the worker whose task
    // queued it, and releases it. The timers are the owner's, which the callbacks are given, or null for a task that never started (a
    // pending task that is dropped), which has no callbacks to call.
    //
    fn finish(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, timers: ?timers_lib.Timers, log: ILog, task: *PoolTask, completion: Completion) void {
        defer destroyTask(allocator, task);
        if (!self.is_shutting_down) {
            if (self.options.sink) |sink| {
                if (task.reply_id_json) |reply_id| {
                    emitReply(allocator, io, sink, reply_id, completion);
                }
                else {
                    emitTaskCompleted(allocator, io, sink, task, completion);
                }
            }
            if (self.options.observe) {
                self.notices.append(allocator, .{
                    .task_end = .{
                        .task_id = allocator.dupe(u8, task.id) catch @panic("out of memory keeping a notice"),
                        .task_type = allocator.dupe(u8, task.task_type) catch @panic("out of memory keeping a notice"),
                        .source = allocator.dupe(u8, task.source) catch @panic("out of memory keeping a notice"),
                        .input_json = allocator.dupe(u8, task.data_json) catch @panic("out of memory keeping a notice"),
                        .status = completion.status,
                        .error_message = if (completion.error_message) |text| allocator.dupe(u8, text) catch @panic("out of memory keeping a notice") else null,
                        .result_json = if (completion.result_json) |text| allocator.dupe(u8, text) catch @panic("out of memory keeping a notice") else null,
                        .started = task.started,
                    },
                }) catch @panic("out of memory keeping a notice");
            }
            if (task.started) {
                const given = timers orelse {
                    std.debug.panic("a task that started ended where no timers were given: {s}", .{task.id});
                };
                self.notifyCompletionCallbacks(io, allocator, given, log, task, completion);
            }
        }
        if (task.keep_alive) {
            self.keep_alive_count -= 1;
            if (self.keep_alive_count == 0 and !self.keep_alive_held) {
                self.callKeepAlive(io, allocator, false);
            }
        }
        if (task.queued_by) |worker_id| {
            for (self.workers.items) |state| {
                if (state.workerId != worker_id) {
                    continue;
                }
                var arena_state = std.heap.ArenaAllocator.init(allocator);
                defer arena_state.deinit();
                const reply = worker_lib.taskCompletedJson(arena_state.allocator(), task.id, task.task_type, task.data_json, completion) catch @panic("out of memory telling a worker a task ended");
                state.worker.postMessage(io, reply) catch @panic("out of memory telling a worker a task ended");
                break;
            }
        }
    }

    //
    // Invokes the IQueueBackend completion callbacks with the task's result, as ITaskResult lays it out. Callback errors are logged.
    //
    fn notifyCompletionCallbacks(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, timers: timers_lib.Timers, log: ILog, task: *PoolTask, completion: Completion) void {
        if (self.completion_callbacks.items.len == 0) {
            return;
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const message = worker_lib.taskCompletedJson(arena, task.id, task.task_type, task.data_json, completion) catch @panic("out of memory reporting a task's end");
        const decoded = worker_messages.decode(worker_messages.IWorkerTaskCompletedMessage, arena, message) catch |err| {
            std.debug.panic("could not read back a task's end ({s}): {s}", .{ @errorName(err), message });
        };
        const completion_keys = callbackKeys(allocator, &self.completion_callbacks);
        defer allocator.free(completion_keys);
        for (completion_keys) |key| {
            const registration = registered(&self.completion_callbacks, key) orelse {
                continue;
            };
            registration.callback.call(io, allocator, timers, log, decoded.result) catch |err| {
                log.exception("Error in task completion callback", err);
            };
        }
    }

    //
    // Releases a task.
    //
    fn destroyTask(allocator: std.mem.Allocator, task: *PoolTask) void {
        allocator.free(task.id);
        allocator.free(task.task_type);
        allocator.free(task.source);
        allocator.free(task.data_json);
        if (task.reply_id_json) |text| {
            allocator.free(text);
        }
        allocator.destroy(task);
    }

    //
    // Drops the pending tasks of the source, each ending as cancelled, tells every worker to cancel the running ones and fires the
    // callbacks registered for the source. Tasks queued under the source afterwards are not affected.
    //
    pub fn cancelSource(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, log: ILog, source: []const u8) void {
        var index: usize = 0;
        while (index < self.pending_tasks.items.len) {
            const task = self.pending_tasks.items[index];
            if (!std.mem.eql(u8, task.source, source)) {
                index += 1;
                continue;
            }
            _ = self.pending_tasks.orderedRemove(index);
            self.finish(io, allocator, null, log, task, .{
                .status = .cancelled,
                .result_json = null,
                .error_message = null,
            });
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const cancel = json.stringify(arena_state.allocator(), .{
            .type = "cancel-tasks",
            .source = source,
        }) catch @panic("out of memory cancelling tasks");
        for (self.workers.items) |state| {
            state.worker.postMessage(io, cancel) catch @panic("out of memory cancelling tasks");
        }
        const cancelled_keys = callbackKeys(allocator, &self.tasks_cancelled_callbacks);
        defer allocator.free(cancelled_keys);
        for (cancelled_keys) |key| {
            const registration = registered(&self.tasks_cancelled_callbacks, key) orelse {
                continue;
            };
            if (std.mem.eql(u8, registration.source, source)) {
                registration.callback.call(io, allocator);
            }
        }
    }

    //
    // Whether any task is queued or running.
    //
    pub fn isBusy(self: *WorkerPool) bool {
        if (self.pending_tasks.items.len > 0) {
            return true;
        }
        for (self.workers.items) |state| {
            if (state.currentTask != null) {
                return true;
            }
        }
        return false;
    }

    //
    // Stops the pool: nothing more is sent to the frontend or started, the pending tasks end as cancelled, every running task is told
    // to cancel, and the pool reads the main queue until each has ended. A message on the main queue from anyone but a worker is
    // handed to `other`, or freed when it is null. Then every worker is sent "shutdown" and the pool waits for its thread to end.
    //
    pub fn shutdown(self: *WorkerPool, io: std.Io, allocator: std.mem.Allocator, timers: timers_lib.Timers, log: ILog, other: ?OtherMessageHandler) void {
        self.is_shutting_down = true;
        while (self.pending_tasks.items.len > 0) {
            const task = self.pending_tasks.orderedRemove(0);
            self.finish(io, allocator, null, log, task, .{
                .status = .cancelled,
                .result_json = null,
                .error_message = null,
            });
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        for (self.workers.items) |state| {
            const task = state.currentTask orelse {
                continue;
            };
            const cancel = json.stringify(arena_state.allocator(), .{
                .type = "cancel-tasks",
                .source = task.source,
            }) catch @panic("out of memory cancelling tasks");
            state.worker.postMessage(io, cancel) catch @panic("out of memory cancelling tasks");
        }
        while (self.isBusy() or self.anyStarting()) {
            const message = self.main_queue.take(io, allocator, .none) orelse {
                break;
            };
            defer allocator.free(message.text);
            if (self.receive(io, allocator, timers, log, message)) {
                continue;
            }
            if (other) |handler| {
                handler.handle(handler.user_data, io, allocator, message);
            }
        }
        for (self.workers.items) |state| {
            state.worker.postMessage(io, "{\"type\":\"shutdown\"}") catch @panic("out of memory stopping a worker");
        }
        for (self.workers.items) |state| {
            state.worker.destroy(allocator);
            allocator.destroy(state);
        }
        self.workers.deinit(allocator);
        self.pending_tasks.deinit(allocator);
        freeList(allocator, &self.completion_callbacks);
        freeList(allocator, &self.event_callbacks);
        freeList(allocator, &self.any_event_callbacks);
        freeList(allocator, &self.task_added_callbacks);
        freeList(allocator, &self.tasks_cancelled_callbacks);
        for (self.notices.items) |notice| {
            notice.deinit(allocator);
        }
        self.notices.deinit(allocator);
    }

    //
    // Whether a worker has been started and has not sent "worker-ready" yet. Shutdown waits for it, so it is not sent "shutdown"
    // before it has read anything.
    //
    fn anyStarting(self: *WorkerPool) bool {
        for (self.workers.items) |state| {
            if (!state.isReady) {
                return true;
            }
        }
        return false;
    }

    //
    // Frees the sources a list of registrations owns, and the list.
    //
    fn freeList(allocator: std.mem.Allocator, list: anytype) void {
        for (list.items) |registration| {
            allocator.free(registration.source);
        }
        list.deinit(allocator);
    }

    //
    // Gets the IQueueBackend interface for this pool. Its functions must be given the owner's
    // allocator, the one every other function of the pool is given, because the pool keeps what they add and register.
    //
    pub fn queueBackend(self: *WorkerPool) IQueueBackend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IQueueBackend functions of this pool.
    //
    const vtable: IQueueBackend.VTable = .{
        .addTask = addTaskErased,
        .onTaskAdded = onTaskAddedErased,
        .onTaskComplete = onTaskCompleteErased,
        .onTaskEvent = onTaskEventErased,
        .onAnyTaskEvent = onAnyTaskEventErased,
        .cancelTasks = cancelTasksErased,
        .onTasksCancelled = onTasksCancelledErased,
        .shutdown = shutdownErased,
        .waitForMessage = waitForMessageErased,
    };

    //
    // Adds a task from the main thread's own code and returns its id (allocated with the allocator, the main thread's). It runs at
    // the priority passed, or at the default (background).
    //
    fn addTaskFromBackend(self: *WorkerPool, allocator: std.mem.Allocator, io: std.Io, log: ILog, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?qtypes.TaskPriority) ![]const u8 {
        if (self.is_shutting_down) {
            return error.ShuttingDown;
        }
        const id = if (taskId) |given| try allocator.dupe(u8, given) else try self.uuid_generator.generate(allocator, io);
        errdefer allocator.free(id);
        const data_json = try json.stringify(allocator, data);
        defer allocator.free(data_json);
        const resolved: TaskPriority = if (priority) |given| switch (given) {
            .Interactive => .interactive,
            .Background => .background,
        } else .background;
        _ = try self.addTaskWithParent(io, allocator, log, id, @"type", source, data_json, resolved, null, null);
        return id;
    }

    //
    // Adds a registration to a callback list and returns the function that removes it.
    //
    fn register(self: *WorkerPool, allocator: std.mem.Allocator, comptime CallbackT: type, list: *std.ArrayList(Registration(CallbackT)), source: []const u8, callback: CallbackT) !qtypes.UnsubscribeFn {
        const source_copy = try allocator.dupe(u8, source);
        errdefer allocator.free(source_copy);
        const key = self.next_key;
        self.next_key += 1;
        try list.append(allocator, .{
            .key = key,
            .source = source_copy,
            .callback = callback,
        });
        return .{
            .context = self,
            .key = key,
            .function = unregister,
        };
    }

    //
    // Removes the registration with the given key from whichever list holds it.
    //
    fn unregister(context: ?*anyopaque, allocator: std.mem.Allocator, key: usize) void {
        const self: *WorkerPool = @ptrCast(@alignCast(context.?));
        removeKey(allocator, qtypes.TaskAddedCallback, &self.task_added_callbacks, key);
        removeKey(allocator, qtypes.WorkerTaskCompletionCallback, &self.completion_callbacks, key);
        removeKey(allocator, qtypes.IEventCallbackEntry, &self.event_callbacks, key);
        removeKey(allocator, qtypes.TaskEventCallback, &self.any_event_callbacks, key);
        removeKey(allocator, qtypes.TasksCancelledCallback, &self.tasks_cancelled_callbacks, key);
    }

    //
    // Removes the registration with the given key from a list, if it is there.
    //
    fn removeKey(allocator: std.mem.Allocator, comptime CallbackT: type, list: *std.ArrayList(Registration(CallbackT)), key: usize) void {
        for (list.items, 0..) |registration, index| {
            if (registration.key == key) {
                allocator.free(registration.source);
                _ = list.orderedRemove(index);
                return;
            }
        }
    }

    //
    // The IQueueBackend addTask of this pool.
    //
    fn addTaskErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, log: ILog, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?qtypes.TaskPriority) anyerror![]const u8 {
        const self: *WorkerPool = @ptrCast(@alignCast(ptr));
        return self.addTaskFromBackend(allocator, io, log, @"type", data, source, taskId, priority);
    }

    //
    // The IQueueBackend onTaskAdded of this pool.
    //
    fn onTaskAddedErased(ptr: *anyopaque, allocator: std.mem.Allocator, source: []const u8, callback: qtypes.TaskAddedCallback) anyerror!qtypes.UnsubscribeFn {
        const self: *WorkerPool = @ptrCast(@alignCast(ptr));
        return self.register(allocator, qtypes.TaskAddedCallback, &self.task_added_callbacks, source, callback);
    }

    //
    // The IQueueBackend onTaskComplete of this pool.
    //
    fn onTaskCompleteErased(ptr: *anyopaque, allocator: std.mem.Allocator, callback: qtypes.WorkerTaskCompletionCallback) anyerror!qtypes.UnsubscribeFn {
        const self: *WorkerPool = @ptrCast(@alignCast(ptr));
        return self.register(allocator, qtypes.WorkerTaskCompletionCallback, &self.completion_callbacks, "", callback);
    }

    //
    // The IQueueBackend onTaskEvent of this pool. The event type must outlive the registration.
    //
    fn onTaskEventErased(ptr: *anyopaque, allocator: std.mem.Allocator, eventType: []const u8, callback: qtypes.TaskEventCallback) anyerror!qtypes.UnsubscribeFn {
        const self: *WorkerPool = @ptrCast(@alignCast(ptr));
        return self.register(allocator, qtypes.IEventCallbackEntry, &self.event_callbacks, "", .{
            .eventType = eventType,
            .callback = callback,
        });
    }

    //
    // The IQueueBackend onAnyTaskEvent of this pool.
    //
    fn onAnyTaskEventErased(ptr: *anyopaque, allocator: std.mem.Allocator, callback: qtypes.TaskEventCallback) anyerror!qtypes.UnsubscribeFn {
        const self: *WorkerPool = @ptrCast(@alignCast(ptr));
        return self.register(allocator, qtypes.TaskEventCallback, &self.any_event_callbacks, "", callback);
    }

    //
    // The IQueueBackend cancelTasks of this pool.
    //
    fn cancelTasksErased(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, log: ILog, source: []const u8) void {
        const self: *WorkerPool = @ptrCast(@alignCast(ptr));
        self.cancelSource(io, allocator, log, source);
    }

    //
    // The IQueueBackend onTasksCancelled of this pool.
    //
    fn onTasksCancelledErased(ptr: *anyopaque, allocator: std.mem.Allocator, source: []const u8, callback: qtypes.TasksCancelledCallback) anyerror!qtypes.UnsubscribeFn {
        const self: *WorkerPool = @ptrCast(@alignCast(ptr));
        return self.register(allocator, qtypes.TasksCancelledCallback, &self.tasks_cancelled_callbacks, source, callback);
    }

    //
    // The IQueueBackend shutdown of this pool: nothing, because the pool's owner shuts it down.
    //
    fn shutdownErased(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        _ = io;
        _ = allocator;
        _ = ptr;
    }

    //
    // The IQueueBackend waitForMessage of this pool: reads the next worker message, or runs the timers that are due (see
    // waitForWorkerMessage).
    //
    fn waitForMessageErased(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: timers_lib.Timers, log: ILog) void {
        const self: *WorkerPool = @ptrCast(@alignCast(ptr));
        self.waitForWorkerMessage(io, allocator, timers, log);
    }
};

//
// Handles a message from the main queue that no worker sent, while the pool shuts down.
//
pub const OtherMessageHandler = struct {
    // The handler's own pointer, passed back on every call.
    user_data: ?*anyopaque,
    // Handles the message, with the main thread's Io and allocator. The pool frees it afterwards.
    handle: *const fn (user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, message: Message) void,
};

//
// Writes a line that came from another thread or the page to the log given, the main thread's, through its ordinary functions with
// `[source] ` in front of it, such as `[Worker 2] `. An exception becomes one error line with its error text under it, as the log of
// the thread the line came from would write it, so the cause is not a second error. The arena is for building the line.
//
pub fn writeTaggedLine(arena: std.mem.Allocator, log: ILog, source: []const u8, line: ziggy_log.log.ILogLine) void {
    const tagged = std.fmt.allocPrint(arena, "[{s}] {s}", .{ source, line.message }) catch @panic("out of memory writing a log line");
    switch (line.level) {
        .info => log.info(tagged),
        .verbose => log.verbose(tagged),
        .@"error" => log.@"error"(tagged),
        .exception => if (line.error_text) |details| {
            log.@"error"(std.fmt.allocPrint(arena, "{s}\n{s}", .{ tagged, details }) catch @panic("out of memory writing a log line"));
        }
        else {
            log.@"error"(tagged);
        },
        .warn => log.warn(tagged),
        .debug => log.debug(tagged),
        .tool => log.tool(tagged, line.tool_output orelse .{
            .stdout = null,
            .stderr = null,
        }),
        .event => log.event(tagged),
    }
}

//
// Writes a worker's log line to the log given, the main thread's, tagged with the source given, such as `Worker 2` (see
// writeTaggedLine).
//
pub fn writeLog(arena: std.mem.Allocator, log: ILog, source: []const u8, text: []const u8) void {
    const message = worker_messages.decode(worker_messages.IWorkerLogMessage, arena, text) catch |err| {
        std.debug.panic("could not read a worker's log message ({s}): {s}", .{ @errorName(err), text });
    };
    var tool_output: ?ziggy_log.log.IToolOutput = null;
    if (message.toolData) |data| {
        tool_output = .{
            .stdout = data.stdout,
            .stderr = data.stderr,
        };
    }
    writeTaggedLine(arena, log, source, .{
        .level = message.level,
        .message = message.message,
        .error_text = message.@"error",
        .tool_output = tool_output,
    });
}

//
// Writes a line a worker wrote to its console to the main thread's console, on the same stream.
//
pub fn writeConsole(arena: std.mem.Allocator, text: []const u8) void {
    const message = worker_messages.decode(worker_messages.IWorkerConsoleMessage, arena, text) catch |err| {
        std.debug.panic("could not read a worker's console message ({s}): {s}", .{ @errorName(err), text });
    };
    if (std.mem.eql(u8, message.stream, "stderr")) {
        ziggy_log.console.@"error"(message.line);
    }
    else {
        ziggy_log.console.log(message.line);
    }
}

//
// The error of a failed task in a task-completed event, laid out like the error objects the frontend reads, with the fields that survive JSON.
//
const ErrorObject = struct {
    // The text of the error.
    message: []const u8,
};

//
// Sends the reply to the frontend message a task was replying to: the task's result on success, or an error reply explaining why not.
//
fn emitReply(allocator: std.mem.Allocator, io: std.Io, sink: EventSink, reply_id_json: []const u8, completion: Completion) void {
    const event = json.stringify(allocator, .{
        .id = json.Raw{
            .text = reply_id_json,
        },
        .ok = completion.status == .succeeded,
        .data = if (completion.status == .succeeded) json.Raw{
            .text = completion.result_json orelse "null",
        } else null,
        .@"error" = switch (completion.status) {
            .succeeded => null,
            .cancelled => "Cancelled",
            .failed => completion.error_message orelse "Failed",
        },
    }) catch @panic("out of memory building a reply");
    defer allocator.free(event);
    sink.emit(sink.user_data, io, event);
}

//
// Tells the frontend a task has ended, with the payload `{taskId, result}`, where result is the full ITaskResult (taskId, status,
// errorMessage, outputs, type, inputs). TaskStatus has no cancelled, so a cancelled task is reported as failed with the error message
// "Cancelled".
//
fn emitTaskCompleted(allocator: std.mem.Allocator, io: std.Io, sink: EventSink, task: *PoolTask, completion: Completion) void {
    const error_message: ?[]const u8 = switch (completion.status) {
        .succeeded => null,
        .cancelled => "Cancelled",
        .failed => completion.error_message orelse "Failed",
    };
    const event = json.stringify(allocator, .{
        .kind = "system",
        .name = "task-completed",
        .data = .{
            .taskId = task.id,
            .result = .{
                .taskId = task.id,
                .status = if (completion.status == .succeeded) "succeeded" else "failed",
                .@"error" = if (error_message) |text| ErrorObject{
                    .message = text,
                } else null,
                .errorMessage = error_message,
                .outputs = if (completion.result_json) |text| json.Raw{
                    .text = text,
                } else null,
                .type = task.task_type,
                .inputs = json.Raw{
                    .text = task.data_json,
                },
            },
        },
    }) catch @panic("out of memory building a task event");
    defer allocator.free(event);
    sink.emit(sink.user_data, io, event);
}
