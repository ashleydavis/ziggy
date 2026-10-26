//
// The core: the main thread, separate from the native app's UI thread, and the calls the native app's thread makes to reach it. The
// main thread's function keeps each piece of its state (the worker pool and its tasks, the timers, the dropped files, the messages
// whose handlers send their response later and the test control state) as a variable of its own, and gives a piece only to the
// functions that use it. Every call from the native app and every response a handler sends later is posted to the main thread's queue
// as a message, and the main thread routes every message from the frontend: a system message (Ziggy's own) to Ziggy's function for its
// name and an app message to the app's handler for its name. Threads talk only by JSON messages (see message-queue.zig).
//
// The app's code reaches the main thread only through the handler services (see services.zig), which every handler, menu item
// function and callback is given with the timers, the Io and an allocator.
//

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const types = @import("types.zig");
const json = @import("json.zig");
const task_runner = @import("task-runner.zig");
const task_queue = @import("task-queue.zig");
const test_control = @import("test-control.zig");
const test_commands = @import("test-commands.zig");
const dropped_files = @import("dropped-files.zig");
const system_messages = @import("system-messages.zig");
const app_lib = @import("app.zig");
const handlers_lib = @import("handlers.zig");
const menu_lib = @import("menu.zig");
const message_queue = @import("message-queue.zig");
const worker_pool = @import("worker-pool.zig");
const worker_lib = @import("worker.zig");
const worker_messages = @import("worker-messages.zig");
const timers_lib = @import("timers.zig");
const services_lib = @import("services.zig");
const ThreadAllocator = @import("thread-allocator.zig").ThreadAllocator;
const native_app = @import("native-app.zig");
const native_message = @import("native-message.zig");
const NativeApp = native_app.NativeApp;
const native_side_lib = @import("native-side.zig");
const NativeSide = native_side_lib.NativeSide;

const ZiggyConfig = types.ZiggyConfig;
const QueueMessage = message_queue.Message;
const TimerList = timers_lib.TimerList;
const TestCommands = test_commands.TestCommands;
const FileLog = task_queue.utils.file_log.FileLog;

pub const MessageQueue = message_queue.MessageQueue;

//
// Registers an app with the core: see app.zig.
//
pub const App = app_lib.App;

//
// An app as App registered it: see app.zig.
//
pub const RegisteredApp = app_lib.RegisteredApp;

//
// The point of the main thread's stop at which the app's on_destroy is called: see app.zig.
//
pub const DestroyPhase = app_lib.DestroyPhase;

//
// An app's function for the query of the frontend's address: see app.zig.
//
pub const UiQuery = app_lib.UiQuery;

//
// One app message, unparsed, for a handler whose payload is ziggy.core.Message: see handlers.zig.
//
pub const Message = handlers_lib.Message;

//
// What a handler that takes ziggy.core.Message returns: see handlers.zig.
//
pub const MessageResult = handlers_lib.MessageResult;

//
// What a message handler returns when its response comes from a task or later: see handlers.zig.
//
pub const Response = handlers_lib.Response;

//
// The task whose result is a message's response: see handlers.zig.
//
pub const ResponseTask = handlers_lib.ResponseTask;

//
// The handle a message handler that sends its response later takes: see handlers.zig.
//
pub const Reply = handlers_lib.Reply;

//
// What handlers reach the main thread through: see services.zig.
//
pub const HandlerServices = services_lib.HandlerServices;

//
// The native app's callbacks a thread of the app's own may call itself: see services.zig.
//
pub const NativeCallbacks = services_lib.NativeCallbacks;

//
// The handler services a timer's callback on the main thread is given: see services.zig.
//
pub const handlerServicesOf = services_lib.handlerServicesOf;

//
// Identifies a timer, for clearing it: see timers.zig.
//
pub const TimerId = timers_lib.TimerId;

//
// A function that gives the text of the error response for an error a handler returned, or null to use the error's name.
//
pub const ErrorDescriber = types.ErrorDescriber;

//
// The number the frontend's messages, which the native app passes on with ziggy_send_message, reach the main thread's queue under.
//
const from_frontend: u32 = 0xFFFF_FFF0;

//
// The number the core's own messages (a stop, a drop, a response a handler sends later) reach the main thread's queue under.
//
const from_core = handlers_lib.from_core;

//
// How the main thread sends the frontend its messages: through the native app's queue (see native-app.zig).
//
pub const Frontend = struct {
    // The native app's queue and how to wake its UI thread.
    native: NativeApp,

    //
    // Sends a JSON message to the native app, and so to the frontend, with the main thread's Io.
    //
    pub fn deliver(self: Frontend, io: std.Io, message: []const u8) void {
        self.native.deliver(io, message) catch @panic("out of memory delivering a message");
    }

    //
    // Sends the successful response to a message.
    //
    fn sendResponse(self: Frontend, io: std.Io, arena: std.mem.Allocator, id: std.json.Value, data_json: []const u8) !void {
        self.deliver(io, try json.stringify(arena, .{
            .id = id,
            .ok = true,
            .data = json.Raw{
                .text = data_json,
            },
        }));
    }

    //
    // Sends a message an error response, or, when there is nothing to respond to, a core-error event.
    //
    fn reportError(self: Frontend, io: std.Io, arena: std.mem.Allocator, id: ?std.json.Value, error_name: []const u8) void {
        if (id) |id_value| {
            self.deliver(io, json.stringify(arena, .{
                .id = id_value,
                .ok = false,
                .@"error" = error_name,
            }) catch @panic("out of memory building an error message"));
            return;
        }
        self.deliver(io, json.stringify(arena, .{
            .kind = "system",
            .name = "core-error",
            .data = .{
                .@"error" = error_name,
            },
        }) catch @panic("out of memory building an error message"));
    }

    //
    // Reports the error a handler returned: the text the app's describe_error gives for it, or else its name.
    //
    fn reportHandlerError(self: Frontend, io: std.Io, arena: std.mem.Allocator, describe_error: ?ErrorDescriber, id: ?std.json.Value, err: anyerror) void {
        const described: ?[]const u8 = if (describe_error) |describe| describe(err) else null;
        self.reportError(io, arena, id, described orelse @errorName(err));
    }
};

//
// A message whose handler took a Reply, as the main thread keeps it until the response comes.
//
const LaterReply = struct {
    // The JSON text of the message's id, or null for a message with no id.
    id_json: ?[]u8,
    // The message's name, which a message that never gets its response is reported by.
    name: []u8,
};

//
// The messages whose handlers took a Reply and have not sent their response yet, by the serial each Reply carries. A piece of the main
// thread's state, whose copies are allocated with the main thread's allocator, which each function that allocates or frees is given.
//
const LaterReplies = struct {
    // The messages by serial.
    entries: std.AutoHashMapUnmanaged(u64, LaterReply),
    // The serial of the next message recorded.
    next_serial: u64,

    const empty: LaterReplies = .{
        .entries = .empty,
        .next_serial = 0,
    };

    //
    // Releases what is left.
    //
    fn deinit(self: *LaterReplies, allocator: std.mem.Allocator) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |later| {
            free(allocator, later.*);
        }
        self.entries.deinit(allocator);
    }

    //
    // Records a message whose handler takes a Reply, before the handler runs, and returns the serial its Reply carries.
    //
    fn open(self: *LaterReplies, allocator: std.mem.Allocator, message: Message) !u64 {
        const id_json: ?[]u8 = if (message.id) |id| try json.stringify(allocator, id) else null;
        errdefer if (id_json) |text| allocator.free(text);
        const name = try allocator.dupe(u8, message.name);
        errdefer allocator.free(name);
        const serial = self.next_serial;
        self.next_serial += 1;
        try self.entries.put(allocator, serial, .{
            .id_json = id_json,
            .name = name,
        });
        return serial;
    }

    //
    // Forgets a message whose handler gave its response by what it returned or failed. A message no longer recorded changes nothing.
    //
    fn close(self: *LaterReplies, allocator: std.mem.Allocator, serial: u64) void {
        const entry = self.entries.fetchRemove(serial) orelse {
            return;
        };
        free(allocator, entry.value);
    }

    //
    // Sends the response another thread posted for a recorded message (a "later-reply" message): its data, or its error. A message no
    // longer recorded has had its response, so a second one is reported as a core-error event naming MessageAlreadyAnswered.
    //
    fn deliver(self: *LaterReplies, io: std.Io, allocator: std.mem.Allocator, arena: std.mem.Allocator, frontend: Frontend, parsed: std.json.Value) void {
        const serial: u64 = @intCast(json.getInteger(parsed, "serial") orelse 0);
        const entry = self.entries.fetchRemove(serial) orelse {
            frontend.reportError(io, arena, null, "MessageAlreadyAnswered");
            return;
        };
        defer free(allocator, entry.value);
        const later = entry.value;
        const id: ?std.json.Value = if (later.id_json) |text| std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch @panic("out of memory sending a response") else null;
        if (json.getString(parsed, "error")) |text| {
            frontend.reportError(io, arena, id, text);
            return;
        }
        const id_value = id orelse {
            return;
        };
        const data = parsed.object.get("data") orelse .null;
        frontend.sendResponse(io, arena, id_value, json.stringify(arena, data) catch @panic("out of memory sending a response")) catch @panic("out of memory sending a response");
    }

    //
    // Reports every message whose handler chose to send its response later and never did, each as a core-error event naming
    // MessageNotAnswered and the message's name, and forgets them. The main thread calls it when it stops.
    //
    fn reportWithoutResponse(self: *LaterReplies, io: std.Io, allocator: std.mem.Allocator, frontend: Frontend) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |later| {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            frontend.reportError(io, arena, null, std.fmt.allocPrint(arena, "MessageNotAnswered: {s}", .{later.name}) catch @panic("out of memory reporting a message with no response"));
            free(allocator, later.*);
        }
        self.entries.clearRetainingCapacity();
    }

    //
    // Releases the copies of a message.
    //
    fn free(allocator: std.mem.Allocator, later: LaterReply) void {
        if (later.id_json) |text| {
            allocator.free(text);
        }
        allocator.free(later.name);
    }
};

//
// The implementation behind the handler services: the pieces of the main thread's state the services reach, on the main thread. It
// keeps no Io or allocator: each function is given the main thread's.
//
const MainServices = struct {
    // The worker pool.
    pool: *worker_pool.WorkerPool,
    // The main thread's queue, which the tasks to add and the sources to cancel are posted to.
    queue: *MessageQueue,
    // Where the app's events go.
    frontend: Frontend,
    // The native app's configuration, with the main thread's copies of its strings.
    config: *const ZiggyConfig,

    const vtable: services_lib.HandlerServices.VTable = .{
        .sendEvent = sendEvent,
        .addTask = addTask,
        .cancelTasks = cancelTasks,
        .holdKeepAlive = holdKeepAlive,
        .quit = quit,
        .menuAction = menuAction,
        .dataDir = dataDir,
        .isPhone = isPhone,
        .nativeCallbacks = nativeCallbacks,
    };

    //
    // The interface handlers are given.
    //
    fn interface(self: *MainServices) services_lib.HandlerServices {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn sendEvent(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, data_json: []const u8) anyerror!void {
        const self: *MainServices = @ptrCast(@alignCast(ptr));
        const event = try json.stringify(allocator, .{
            .kind = "app",
            .data = json.Raw{
                .text = data_json,
            },
        });
        defer allocator.free(event);
        self.frontend.deliver(io, event);
    }

    //
    // Queues a task. The worker pool keeps its tasks for longer than the handler's allocator lives, so the task is posted to the main
    // thread's queue and added by the main thread with its own allocator once the handler has returned (see addTaskLater).
    //
    fn addTask(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, task_id: []const u8, task_type: []const u8, source: []const u8, data_json: []const u8, priority: task_runner.TaskPriority) anyerror!void {
        const self: *MainServices = @ptrCast(@alignCast(ptr));
        if (self.pool.is_shutting_down) {
            return error.ShuttingDown;
        }
        const message = try json.stringify(allocator, AddTaskMessage{
            .type = "add-task",
            .taskId = task_id,
            .taskType = task_type,
            .source = source,
            .data = json.Raw{
                .text = data_json,
            },
            .priority = priority,
        });
        defer allocator.free(message);
        try self.queue.post(io, from_core, message);
    }

    //
    // Cancels the tasks of a source, posted to the main thread's queue as addTask is, so it is carried out after the tasks the handler
    // added before it.
    //
    fn cancelTasks(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, source: []const u8) void {
        const self: *MainServices = @ptrCast(@alignCast(ptr));
        const message = json.stringify(allocator, .{
            .type = "cancel-tasks",
            .source = source,
        }) catch @panic("out of memory cancelling tasks");
        defer allocator.free(message);
        self.queue.post(io, from_core, message) catch @panic("out of memory cancelling tasks");
    }

    fn holdKeepAlive(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, keep_running: bool) void {
        const self: *MainServices = @ptrCast(@alignCast(ptr));
        self.pool.holdKeepAlive(io, allocator, keep_running);
    }

    fn quit(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        const self: *MainServices = @ptrCast(@alignCast(ptr));
        if (!self.config.has_quit) {
            return;
        }
        self.callNative(io, allocator, .quit);
    }

    fn menuAction(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, action: []const u8) void {
        const self: *MainServices = @ptrCast(@alignCast(ptr));
        if (!self.config.has_menu_action) {
            return;
        }
        self.callNative(io, allocator, .{
            .menu_action = action,
        });
    }

    //
    // Has the native app do something that has no result.
    //
    fn callNative(self: *MainServices, io: std.Io, allocator: std.mem.Allocator, call: native_message.Call) void {
        self.frontend.native.call(io, allocator, call, null) catch @panic("out of memory calling the native app");
    }

    fn dataDir(ptr: *anyopaque) []const u8 {
        const self: *MainServices = @ptrCast(@alignCast(ptr));
        return std.mem.span(self.config.data_dir);
    }

    fn isPhone(ptr: *anyopaque) bool {
        const self: *MainServices = @ptrCast(@alignCast(ptr));
        return self.config.has_native_call;
    }

    fn nativeCallbacks(ptr: *anyopaque) services_lib.NativeCallbacks {
        const self: *MainServices = @ptrCast(@alignCast(ptr));
        return .{
            .native = self.frontend.native,
            .has_native_call = self.config.has_native_call,
        };
    }

    //
    // The pool's sink: delivers a message the pool produced to the frontend.
    //
    fn emit(user_data: ?*anyopaque, io: std.Io, message: []const u8) void {
        const self: *MainServices = @ptrCast(@alignCast(user_data.?));
        self.frontend.deliver(io, message);
    }

    //
    // The pool's keep-alive handler: tells the native app whether the app must keep running for tasks.
    //
    fn setKeepAlive(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, keep_running: bool) void {
        const self: *MainServices = @ptrCast(@alignCast(user_data.?));
        if (!self.config.has_keep_alive) {
            return;
        }
        self.callNative(io, allocator, .{
            .keep_alive = keep_running,
        });
    }
};

//
// A task a handler added, as it is posted to the main thread's queue (see MainServices.addTask).
//
const AddTaskMessage = struct {
    // "add-task".
    type: []const u8,
    // The task's id.
    taskId: []const u8,
    // The task type.
    taskType: []const u8,
    // The source the task is cancelled by.
    source: []const u8,
    // The task's input, as JSON text when it is written and as a value when it is read.
    data: json.Raw,
    // How urgent the task is.
    priority: task_runner.TaskPriority,
};

//
// Adds a task a handler posted (see MainServices.addTask), with the main thread's allocator. A task that cannot be added is reported
// as a core-error event, because the handler that added it has returned.
//
fn addTaskLater(io: std.Io, allocator: std.mem.Allocator, arena: std.mem.Allocator, frontend: Frontend, pool: *worker_pool.WorkerPool, parsed: std.json.Value) void {
    const added = worker_messages.decodeValue(struct {
        taskId: []const u8,
        taskType: []const u8,
        source: []const u8,
        data: std.json.Value = .null,
        priority: task_runner.TaskPriority,
    }, arena, parsed) catch |err| {
        std.debug.panic("the main thread could not read a task a handler added ({s})", .{@errorName(err)});
    };
    const data_json = json.stringify(arena, added.data) catch @panic("out of memory adding a task");
    pool.addTask(io, allocator, added.taskId, added.taskType, added.source, data_json, added.priority, null) catch |err| {
        frontend.reportError(io, arena, null, @errorName(err));
    };
}

//
// Calls the app's on_task_end and on_task_event for each notice the worker pool kept of a task that ended or an event a task sent
// (see WorkerPool.takeNotice), with the standard arguments of a handler, in the order they happened.
//
fn tellApp(pool: *worker_pool.WorkerPool, app: RegisteredApp, services: services_lib.HandlerServices, timers: timers_lib.Timers, io: std.Io, allocator: std.mem.Allocator) void {
    while (pool.takeNotice()) |notice| {
        defer notice.deinit(allocator);
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        switch (notice) {
            .task_end => |end| if (app.on_task_end) |on_task_end| {
                on_task_end(services, timers, io, arena_state.allocator(), end);
            },
            .task_event => |sent| if (app.on_task_event) |on_task_event| {
                on_task_event(services, timers, io, arena_state.allocator(), sent);
            },
        }
    }
}

//
// What the main thread handles a task's `native-app-request` with: the native app's configuration and queue, the test commands (for a
// dialog result a test supplied) and whether the main thread is stopping. It keeps no Io or allocator: each call is given the main
// thread's.
//
const NativeCalls = struct {
    // The native app's configuration.
    config: *const ZiggyConfig,
    // The native app's queue.
    frontend: Frontend,
    // The test commands.
    tests: *TestCommands,
    // Set once the main thread has read the stop, so a request is refused instead of reaching the native app.
    stopping: *const bool,
    // Gives the text of the reason a call failed, or null to use the error's name.
    describe_error: ?ErrorDescriber,

    //
    // Handles a task's request to the native app: posts the native app a call of the function it names, whose result the native app
    // sends straight to the worker's queue as a `native-app-response`. A request the main thread can respond to itself is handled here:
    // once the main thread is stopping the native app is not called and the request fails with ShuttingDown, a dialog whose result a
    // test supplied gives it, and a function the native app does not have fails with NativeCallMissing.
    //
    fn handle(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, worker: *worker_lib.Worker, request_json: []const u8) void {
        const self: *NativeCalls = @ptrCast(@alignCast(user_data.?));
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const request = worker_messages.decode(worker_messages.INativeAppRequestMessage, arena, request_json) catch |err| {
            std.debug.panic("could not read a native app request ({s}): {s}", .{ @errorName(err), request_json });
        };
        const handled = self.respondHere(allocator, arena, request) catch |err| worker_lib.NativeResponse{
            .failure = if (self.describe_error) |describe| (describe(err) orelse @errorName(err)) else @errorName(err),
        };
        const outcome = handled orelse {
            const call = callOf(arena, request) catch |err| {
                std.debug.panic("could not read a native app request ({s}): {s}", .{ @errorName(err), request_json });
            };
            self.frontend.native.call(io, arena, call, .{
                .queue = &worker.queue,
                .call_id = request.requestId,
            }) catch @panic("out of memory calling the native app");
            return;
        };
        const response = switch (outcome) {
            .result => |text| json.stringify(arena, .{
                .type = "native-app-response",
                .requestId = request.requestId,
                .result = text,
            }),
            .failure => |text| json.stringify(arena, .{
                .type = "native-app-response",
                .requestId = request.requestId,
                .@"error" = text,
            }),
        } catch @panic("out of memory sending a native app response");
        worker.postMessage(io, response) catch @panic("out of memory sending a native app response");
    }

    //
    // The outcome of a request the main thread handles without the native app, or null when the native app is to be called.
    //
    fn respondHere(self: *NativeCalls, allocator: std.mem.Allocator, arena: std.mem.Allocator, request: worker_messages.INativeAppRequestMessage) !?worker_lib.NativeResponse {
        if (self.stopping.*) {
            return .{
                .failure = "ShuttingDown",
            };
        }
        const Function = worker_messages.NativeAppFunction;
        const has_function = if (std.mem.eql(u8, request.function, Function.pick_paths)) blk: {
            if (self.tests.takePickResult()) |picked| {
                defer allocator.free(picked);
                return .{
                    .result = try arena.dupe(u8, picked),
                };
            }
            break :blk self.config.has_pick_paths;
        } else if (std.mem.eql(u8, request.function, Function.native_call))
            self.config.has_native_call
        else if (std.mem.eql(u8, request.function, Function.os_version))
            self.config.has_os_version
        else
            std.debug.panic("a task requested a native app function that does not exist: {s}", .{request.function});
        if (!has_function) {
            return .{
                .failure = "NativeCallMissing",
            };
        }
        return null;
    }
};

//
// The call to the native app a task's request is for.
//
fn callOf(arena: std.mem.Allocator, request: worker_messages.INativeAppRequestMessage) !native_message.Call {
    const Function = worker_messages.NativeAppFunction;
    if (std.mem.eql(u8, request.function, Function.pick_paths)) {
        const input = try worker_messages.decodeValue(worker_messages.PickPathsInput, arena, request.input);
        return .{
            .pick_paths = .{
                .kind = input.kind,
                .title = input.title,
                .initial_name = input.initialName,
            },
        };
    }
    if (std.mem.eql(u8, request.function, Function.native_call)) {
        const input = try worker_messages.decodeValue(worker_messages.NativeCallInput, arena, request.input);
        return .{
            .native_call = .{
                .method = input.method,
                .request = input.request,
            },
        };
    }
    return .os_version;
}

//
// A single threaded Io of the calling thread's own, for a call from the native app's UI thread, which must not use another thread's.
//
fn ownIo(allocator: std.mem.Allocator) std.Io.Threaded {
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    return threaded;
}

//
// Starts the main thread, which makes its state on its own thread, posts to and reads from `queue`, starts the app's file log and calls
// the app's `on_create` there, and waits for it to report that it has started. The main thread reaches the native app only by posting to `native_queue`,
// the native app's queue (see native-side.zig), and waking the native app's UI thread with the config's wake. The caller owns both
// queues, which must stay where they are until `stop` has returned, and the returned thread, which it gives to `stop`. An error
// `on_create` returned is returned here, after the main thread has released what it made and ended.
//
pub fn start(allocator: std.mem.Allocator, queue: *MessageQueue, native_queue: *MessageQueue, config: ZiggyConfig, app: RegisteredApp) !std.Thread {
    const wake = config.wake orelse {
        return error.WakeCallbackMissing;
    };
    var started = MessageQueue.init();
    defer started.deinit();
    var threaded = ownIo(allocator);
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The native app's strings are valid only during this call, so they are the first message in the main thread's queue, which it
    // takes copies of with its own allocator. The main thread is given the configuration with no strings.
    try queue.post(io, from_core, try startJson(arena, config));
    var given = config;
    given.app_url_prefix = "";
    given.data_dir = "";
    given.test_port_file = null;
    const thread = try std.Thread.spawn(.{}, mainThread, .{MainStart{
        .queue = queue,
        .started = &started,
        .native = .{
            .queue = native_queue,
            .wake = wake,
            .wake_data = config.wake_data,
        },
        .config = given,
        .app = app,
    }});
    const report = started.take(io, arena, .none) orelse {
        @panic("the main thread's start queue closed");
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, report.text, .{}) catch {
        std.debug.panic("the main thread reported its start with text that is not JSON: {s}", .{report.text});
    };
    if (json.getInteger(parsed, "error")) |error_number| {
        // The main thread has released what it made and is ending.
        thread.join();
        // The error the main thread failed with, by its number, which is the same on every thread of the process.
        return @errorFromInt(@as(std.meta.Int(.unsigned, @bitSizeOf(anyerror)), @intCast(error_number)));
    }
    return thread;
}

//
// Has the main thread stop and waits for it to end: it calls the app's `on_destroy` with `.before_tasks_stop`, clears its timers,
// cancels every task, sends every worker "shutdown", stops the test control connection, waits for all of them to end,
// stops the app's file log, calls `on_destroy` with `.after_tasks_stopped`, tells the native app it has stopped and releases its state. Meanwhile the native app's side
// gives every call the result ShuttingDown (see NativeSide.stop), because the native app's UI thread is the one waiting here, and hands the
// messages for the frontend to `frontend`, or drops them when it is null. The caller frees the queues afterwards.
//
pub fn stop(allocator: std.mem.Allocator, queue: *MessageQueue, native: *NativeSide, frontend: ?native_side_lib.FrontendSink, thread: std.Thread) void {
    var threaded = ownIo(allocator);
    defer threaded.deinit();
    queue.post(threaded.io(), from_core, "{\"type\":\"stop\"}") catch @panic("out of memory stopping the main thread");
    native.stop(threaded.io(), allocator, frontend);
    thread.join();
}

//
// Passes a message from the frontend to the main thread and returns at once. The message's handler runs later, on the main thread, in
// the order the messages were sent. The native app calls it for each message, with the text valid only during the call.
//
pub fn sendMessage(allocator: std.mem.Allocator, queue: *MessageQueue, message: []const u8) void {
    var threaded = ownIo(allocator);
    defer threaded.deinit();
    queue.post(threaded.io(), from_frontend, message) catch @panic("out of memory passing a message to the main thread");
}

//
// Records the files the user dropped on the window, replacing the last drop. The native app calls it when the drop happens, before the
// frontend's own drop event, with the paths as the JSON text of an array of strings. The paths are checked on the calling thread, which
// this returns the result of, and the main thread records the drop: it reads it before any message the frontend sends after this
// returns, such as the frontend's getPathForFile.
//
pub fn filesDropped(allocator: std.mem.Allocator, queue: *MessageQueue, paths_json: []const u8) !void {
    var threaded = ownIo(allocator);
    defer threaded.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files_json = try dropped_files.check(arena, threaded.io(), paths_json);
    try queue.post(threaded.io(), from_core, try json.stringify(arena, .{
        .type = "files-dropped",
        .files = json.Raw{
            .text = files_json,
        },
    }));
}

//
// Has the main thread call the app's function for the query of the frontend's address, waits for it and returns the text after the
// question mark, empty when the app has none, allocated with the allocator, which the caller frees it with. The native app calls it once
// the core exists, before it loads the frontend.
//
pub fn uiQuery(allocator: std.mem.Allocator, queue: *MessageQueue) ![:0]u8 {
    var threaded = ownIo(allocator);
    defer threaded.deinit();
    const call_io = threaded.io();
    var replies = MessageQueue.init();
    defer replies.deinit();
    try queue.postReplyTo(call_io, from_core, "{\"type\":\"ui-query\"}", &replies);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const reply = replies.take(call_io, arena_state.allocator(), .none) orelse {
        @panic("the reply queue of ui-query closed");
    };
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), reply.text, .{});
    if (json.getString(parsed, "error")) |reason| {
        std.debug.print("the app's ui_query failed: {s}\n", .{reason});
        return error.UiQueryFailed;
    }
    return try allocator.dupeZ(u8, json.getString(parsed, "text") orelse "");
}

//
// What the main thread is given when it starts: the queues it talks to the native side through, the native app's configuration with no
// strings, and the app's registration, constants of the app's code. The strings come in the start message (see StartMessage).
//
const MainStart = struct {
    // The main thread's messages, which the caller of `start` owns. Its first message is the start message.
    queue: *MessageQueue,
    // Where the main thread reports that it has started, or why it could not. It is used only until then.
    started: *MessageQueue,
    // The native app's queue and how to wake its UI thread.
    native: NativeApp,
    // The native app's configuration, with its strings empty.
    config: ZiggyConfig,
    // What the app adds to the core.
    app: RegisteredApp,
};

//
// The first message in the main thread's queue: the native app's strings and the environment of the thread that created the core.
//
const StartMessage = struct {
    // The URL prefix of the app's own bundled frontend.
    appUrlPrefix: []const u8,
    // The app's private data directory.
    dataDir: []const u8,
    // The file the test control connection writes its port to, or null for none.
    testPortFile: ?[]const u8 = null,
    // The environment of the thread that created the core, as a JSON object of names and values, which the main thread sets as its own
    // (see process-env.zig), or null when that thread had none.
    environment: ?std.json.Value = null,
};

//
// The JSON text of the start message, from the native app's configuration and the calling thread's environment, allocated with the
// arena.
//
fn startJson(arena: std.mem.Allocator, config: ZiggyConfig) ![]u8 {
    const environment: ?std.json.Value = if (task_queue.utils.process_env.getEnvironMap()) |map| try worker_lib.environmentJson(arena, map) else null;
    return try json.stringify(arena, StartMessage{
        .appUrlPrefix = std.mem.span(config.app_url_prefix),
        .dataDir = std.mem.span(config.data_dir),
        .testPortFile = if (config.test_port_file) |path| std.mem.span(path) else null,
        .environment = environment,
    });
}

//
// Reports on the start queue that the main thread could not start, and why.
//
fn reportStartFailure(main_start: *MainStart, io: std.Io, err: anyerror) void {
    var buffer: [64]u8 = undefined;
    const failure = std.fmt.bufPrint(&buffer, "{{\"error\":{d}}}", .{@intFromError(err)}) catch unreachable;
    main_start.started.post(io, 0, failure) catch @panic("out of memory reporting that the main thread could not start");
}

//
// Starts the app's file log, named after the app and headed with its title and version, and installs it as the main thread's log. The files go in the `logs` directory of the
// directory `<NAME>_LOG_DIR` names (the app's name in capitals with each dash as an underscore, such as ZIGGY_TEMPLATE_LOG_DIR) when it is
// set, or else in the `logs` directory of the app's data directory. It is allocated with the main thread's allocator and stopped on the
// main thread.
//
fn startFileLog(allocator: std.mem.Allocator, name: []const u8, title: []const u8, version: ?[]const u8, data_dir: []const u8, io: std.Io) !*FileLog {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const variable = try std.mem.concat(arena, u8, &.{ name, "_LOG_DIR" });
    for (variable) |*character| {
        character.* = if (character.* == '-') '_' else std.ascii.toUpper(character.*);
    }
    const logs_parent = try environmentVariable(arena, variable) orelse data_dir;
    return try FileLog.start(allocator, io, .{
        .file_prefix = name,
        .title = title,
        .logs_dir = try std.fs.path.join(arena, &.{ logs_parent, "logs" }),
        .command = null,
        .version = version,
        .header_lines = &.{},
        .verbose = false,
        .debug = false,
        .tools = false,
    });
}

//
// The value of an environment variable: from the environment the native app gave the core when it gave one, or else from the process's.
// Allocated with the arena when it is read from the process.
//
fn environmentVariable(arena: std.mem.Allocator, variable: []const u8) !?[]const u8 {
    if (task_queue.utils.process_env.getEnvironMap() != null) {
        return task_queue.utils.process_env.getEnv(variable);
    }
    const environ: std.process.Environ = switch (builtin.os.tag) {
        .windows => .{
            .block = .global,
        },
        else => .{
            .block = .{
                .slice = std.mem.span(std.c.environ),
            },
        },
    };
    const map = try environ.createMap(arena);
    return map.get(variable);
}

//
// The main thread: makes each piece of its state, starts the app's file log, calls the app's on_create, reports that it has started, then reads its messages,
// waiting no longer than until the next timer is due, and runs the timers that are due, until it has done everything a stop requires. Then
// it releases its state.
//
fn mainThread(given: MainStart) void {
    var main_start = given;
    // The main thread's own allocator, which everything on its thread is allocated with.
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    const queue = main_start.queue;
    const app = main_start.app;
    var threaded = ownIo(allocator);
    defer threaded.deinit();
    const io = threaded.io();
    // The main thread's copies of the native app's strings, from the start message, kept until it ends.
    var start_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer start_arena_state.deinit();
    const start_arena = start_arena_state.allocator();
    const start_message = queue.take(io, start_arena, .none) orelse {
        @panic("the main thread's queue closed before it was sent its start");
    };
    const start_data = std.json.parseFromSliceLeaky(StartMessage, start_arena, start_message.text, .{}) catch |err| {
        std.debug.panic("the main thread could not read its start message ({s}): {s}", .{ @errorName(err), start_message.text });
    };
    var config = main_start.config;
    config.app_url_prefix = (start_arena.dupeZ(u8, start_data.appUrlPrefix) catch @panic("out of memory starting the main thread")).ptr;
    config.data_dir = (start_arena.dupeZ(u8, start_data.dataDir) catch @panic("out of memory starting the main thread")).ptr;
    config.test_port_file = if (start_data.testPortFile) |path| (start_arena.dupeZ(u8, path) catch @panic("out of memory starting the main thread")).ptr else null;
    var environment: ?std.process.Environ.Map = if (start_data.environment) |value| worker_lib.environmentFromJson(allocator, value) catch |err| {
        std.debug.panic("the main thread could not read its environment: {s}", .{@errorName(err)});
    } else null;
    defer if (environment) |*map| map.deinit();
    task_queue.utils.process_env.setEnvironMap(if (environment) |*map| map else null);
    defer task_queue.utils.process_env.setEnvironMap(null);
    const frontend: Frontend = .{
        .native = main_start.native,
    };
    // The main thread's own timers.
    var timer_list = TimerList.init();
    const timers = timer_list.interface();
    var dropped: dropped_files.DroppedFiles = .empty;
    defer dropped.deinit(allocator);
    var later_replies: LaterReplies = .empty;
    defer later_replies.deinit(allocator);
    var tests = TestCommands.init(frontend);
    defer tests.deinit(allocator);
    var uuid_generator: task_queue.utils.random_uuid_generator.RandomUuidGenerator = .{};
    const session_id = uuid_generator.generate(allocator, io) catch |err| {
        reportStartFailure(&main_start, io, err);
        return;
    };
    defer allocator.free(session_id);
    var stopping = false;
    var pool: worker_pool.WorkerPool = undefined;
    var main_services: MainServices = .{
        .pool = &pool,
        .queue = queue,
        .frontend = frontend,
        .config = &config,
    };
    const services = main_services.interface();
    var native_calls: NativeCalls = .{
        .config = &config,
        .frontend = frontend,
        .tests = &tests,
        .stopping = &stopping,
        .describe_error = app.describe_error,
    };
    pool = worker_pool.WorkerPool.init(queue, .{
        .max_workers = @max(config.worker_threads, 1),
        .tasks = app.tasks,
        .describe_error = app.describe_error,
        .worker_options = .{
            .workerId = 0,
            .sessionId = session_id,
            .maxConcurrentChildTasks = config.max_concurrent_child_tasks,
            .hasNativeCall = config.has_native_call,
            .hasOsVersion = config.has_os_version,
            .dataDir = std.mem.span(config.data_dir),
        },
        .sink = .{
            .user_data = &main_services,
            .emit = MainServices.emit,
        },
        .observe = app.on_task_end != null or app.on_task_event != null,
        .native_request = .{
            .user_data = &native_calls,
            .handle = NativeCalls.handle,
        },
        .keep_alive = .{
            .user_data = &main_services,
            .set = MainServices.setKeepAlive,
        },
    });
    // The app's file log, the main thread's log from before on_create until after on_destroy, or null for an app without one.
    var file_log: ?*FileLog = null;
    const start_failure: ?anyerror = failed: {
        if (build_options.test_hooks and config.test_mode) {
            tests.connection = test_control.TestControl.start(allocator, io, config, frontend.native, queue) catch |err| {
                break :failed err;
            };
        }
        if (app.name) |name| {
            file_log = startFileLog(allocator, name, app.title orelse name, app.version, std.mem.span(config.data_dir), io) catch |err| {
                break :failed err;
            };
        }
        if (app.on_create) |on_create| {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            on_create(services, timers, io, arena_state.allocator()) catch |err| {
                break :failed err;
            };
        }
        break :failed null;
    };
    if (start_failure) |err| {
        tests.stop(io, allocator, queue);
        pool.shutdown(io, allocator, timers, null);
        if (file_log) |logger| {
            logger.stop(allocator, io);
        }
        reportStartFailure(&main_start, io, err);
        return;
    }
    main_start.started.post(io, 0, "{}") catch @panic("out of memory reporting that the main thread has started");
    var next_request_task: u64 = 0;
    var stopped = false;
    while (!stopped) {
        const taken = queue.take(io, allocator, timer_list.nextTimeout());
        if (taken) |message| {
            defer allocator.free(message.text);
            switch (message.from) {
                from_frontend => {
                    if (!stopping) {
                        handleFrontendMessage(allocator, frontend, app, services, timers, io, queue, &later_replies, &pool, &dropped, &tests, &next_request_task, message.text);
                    }
                },
                from_core => {
                    var arena_state = std.heap.ArenaAllocator.init(allocator);
                    defer arena_state.deinit();
                    const arena = arena_state.allocator();
                    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, message.text, .{}) catch {
                        std.debug.panic("the core sent the main thread a message that is not JSON: {s}", .{message.text});
                    };
                    const message_type = json.getString(parsed, "type") orelse "";
                    if (std.mem.eql(u8, message_type, "stop")) {
                        stopping = true;
                        if (app.on_destroy) |on_destroy| {
                            on_destroy(services, timers, io, arena, .before_tasks_stop);
                        }
                        timer_list.clearAll();
                        pool.shutdown(io, allocator, timers, .{
                            .user_data = null,
                            .handle = refuseWhileStopping,
                        });
                        later_replies.reportWithoutResponse(io, allocator, frontend);
                        tests.refuseWhileStopping(io, allocator);
                        tests.stop(io, allocator, queue);
                        // Stopped once every task has ended, so the tasks' last lines are written before the footer, and before the
                        // app frees its resources, so what the app logs then goes to the console.
                        if (file_log) |logger| {
                            logger.stop(allocator, io);
                        }
                        if (app.on_destroy) |on_destroy| {
                            on_destroy(services, timers, io, arena, .after_tasks_stopped);
                        }
                        // The last message the native app is sent, which ends its wait for the stop.
                        frontend.native.call(io, arena, .stopped, null) catch @panic("out of memory stopping the main thread");
                        stopped = true;
                    }
                    else if (std.mem.eql(u8, message_type, "files-dropped")) {
                        const files = parsed.object.get("files") orelse .null;
                        dropped.record(allocator, json.stringify(arena, files) catch @panic("out of memory recording a drop")) catch |err| {
                            frontend.reportError(io, arena, null, @errorName(err));
                        };
                    }
                    else if (std.mem.eql(u8, message_type, "add-task")) {
                        addTaskLater(io, allocator, arena, frontend, &pool, parsed);
                    }
                    else if (std.mem.eql(u8, message_type, "cancel-tasks")) {
                        pool.cancelSource(io, allocator, json.getString(parsed, "source") orelse "");
                    }
                    else if (std.mem.eql(u8, message_type, "later-reply")) {
                        later_replies.deliver(io, allocator, arena, frontend, parsed);
                    }
                    else if (std.mem.eql(u8, message_type, "ui-query")) {
                        const reply_to = message.reply_to orelse {
                            @panic("ui-query was sent with nowhere to reply");
                        };
                        const reply = runUiQuery(arena, app.ui_query, services, timers, io, config.test_mode) catch |err| json.stringify(arena, .{
                            .@"error" = @errorName(err),
                        }) catch @panic("out of memory replying to ui-query");
                        reply_to.post(io, 0, reply) catch @panic("out of memory replying to ui-query");
                    }
                    else {
                        std.debug.panic("the core sent the main thread a message of an unknown type: {s}", .{message.text});
                    }
                },
                test_control.from_test_control => {
                    // Only a build with the test hooks has a test control connection, so only it has the code that handles its
                    // messages.
                    if (build_options.test_hooks) {
                        tests.handleMessage(io, allocator, timers, &dropped, message);
                    }
                },
                else => {
                    if (!pool.receive(io, allocator, timers, message)) {
                        std.debug.panic("the main thread was sent a message by nobody it knows ({d}): {s}", .{ message.from, message.text });
                    }
                },
            }
        }
        if (!stopping) {
            timer_list.runDue(io, allocator, &services);
            tellApp(&pool, app, services, timers, io, allocator);
        }
    }
}

//
// Handles a message that reaches the main thread while the worker pool stops, which no worker sent: a command from the test control
// connection is refused with ShuttingDown, so the connection stops waiting, and anything else is dropped.
//
fn refuseWhileStopping(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, message: QueueMessage) void {
    _ = user_data;
    _ = allocator;
    TestCommands.refuse(io, message);
}

//
// Calls the app's function for the query of the frontend's address and returns the reply to ui-query: `{"text": ...}`.
//
fn runUiQuery(arena: std.mem.Allocator, ui_query: ?UiQuery, services: services_lib.HandlerServices, timers: timers_lib.Timers, io: std.Io, test_mode: bool) ![]u8 {
    const query = ui_query orelse {
        return try json.stringify(arena, .{
            .text = "",
        });
    };
    return try json.stringify(arena, .{
        .text = try query(services, timers, io, arena, test_mode),
    });
}

//
// Handles one message from the frontend or the native app: the one entry point for both kinds of message. It parses the envelope and
// passes it on by its kind, "app" to runAppMessage and "system" to runSystemMessage, and does nothing else. A message that is not a
// JSON object, or has no kind or any other kind, is refused as InvalidMessage, reported as a core-error system event.
//
fn handleFrontendMessage(allocator: std.mem.Allocator, frontend: Frontend, app: RegisteredApp, services: services_lib.HandlerServices, timers: timers_lib.Timers, io: std.Io, queue: *MessageQueue, later_replies: *LaterReplies, pool: *worker_pool.WorkerPool, dropped: *dropped_files.DroppedFiles, tests: *TestCommands, next_request_task: *u64, text: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
        frontend.reportError(io, arena, null, "InvalidMessage");
        return;
    };
    if (parsed != .object) {
        frontend.reportError(io, arena, null, "InvalidMessage");
        return;
    }
    const kind = parsed.object.get("kind") orelse .null;
    if (kind == .string and std.mem.eql(u8, kind.string, "app")) {
        runAppMessage(allocator, arena, frontend, app, services, timers, io, queue, later_replies, pool, next_request_task, parsed);
        return;
    }
    if (kind == .string and std.mem.eql(u8, kind.string, "system")) {
        runSystemMessage(allocator, arena, frontend, app, services, timers, io, pool, dropped, tests, parsed);
        return;
    }
    frontend.reportError(io, arena, null, "InvalidMessage");
}

//
// The name of a message, or null when it has none, an empty one or one that is not a string.
//
fn messageName(parsed: std.json.Value) ?[]const u8 {
    const value = parsed.object.get("name") orelse {
        return null;
    };
    if (value != .string or value.string.len == 0) {
        return null;
    }
    return value.string;
}

//
// The app's handler of a message name, or null when the app has none.
//
fn findMessage(messages: []const handlers_lib.MessageEntry, name: []const u8) ?handlers_lib.MessageEntry {
    for (messages) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry;
        }
    }
    return null;
}

//
// Handles an app message: runs the app's handler for its name, with the standard arguments, and sends the response when the message
// carries an id: the response, an error response when the handler failed, or the InvalidMessageData text when the data did not fit the
// handler's payload (the handler then did not run). A failure of a message that has no id is reported as a core-error system event,
// never dropped silently. A message must carry a name, a string that is not empty, or it is refused with MissingMessageName, and a name
// the app has no handler for is UnknownMessageName; neither runs a handler. The allocator is the main thread's, which what outlives the
// message is allocated with, and the arena is freed when the message has been handled.
//
fn runAppMessage(allocator: std.mem.Allocator, arena: std.mem.Allocator, frontend: Frontend, app: RegisteredApp, services: services_lib.HandlerServices, timers: timers_lib.Timers, io: std.Io, queue: *MessageQueue, later_replies: *LaterReplies, pool: *worker_pool.WorkerPool, next_request_task: *u64, parsed: std.json.Value) void {
    const request_id: ?std.json.Value = parsed.object.get("id");
    const name = messageName(parsed) orelse {
        frontend.reportError(io, arena, request_id, "MissingMessageName");
        return;
    };
    const entry = findMessage(app.messages, name) orelse {
        frontend.reportError(io, arena, request_id, "UnknownMessageName");
        return;
    };
    const message: Message = .{
        .id = request_id,
        .name = name,
        .data = parsed.object.get("data") orelse .null,
    };
    var reply: ?handlers_lib.ReplyTarget = null;
    if (entry.takes_reply) {
        const serial = later_replies.open(allocator, message) catch |err| {
            frontend.reportError(io, arena, request_id, @errorName(err));
            return;
        };
        reply = .{
            .queue = queue,
            .describe_error = app.describe_error,
            .serial = serial,
        };
    }
    const outcome = entry.handler(services, timers, io, arena, message, reply) catch |err| {
        if (reply) |target| {
            later_replies.close(allocator, target.serial);
        }
        frontend.reportHandlerError(io, arena, app.describe_error, request_id, err);
        return;
    };
    const result = switch (outcome) {
        .result => |returned| returned,
        .invalid_data => |text| {
            if (reply) |target| {
                later_replies.close(allocator, target.serial);
            }
            frontend.reportError(io, arena, request_id, text);
            return;
        },
    };
    if (reply) |target| {
        if (result != .later) {
            later_replies.close(allocator, target.serial);
        }
    }
    switch (result) {
        .response => |text| {
            const id = request_id orelse {
                return;
            };
            frontend.sendResponse(io, arena, id, text) catch |err| {
                frontend.reportError(io, arena, null, @errorName(err));
            };
        },
        .none => {
            const id = request_id orelse {
                return;
            };
            frontend.sendResponse(io, arena, id, "null") catch |err| {
                frontend.reportError(io, arena, null, @errorName(err));
            };
        },
        .task => |task| {
            const id = request_id orelse {
                frontend.reportHandlerError(io, arena, app.describe_error, null, error.MessageHasNoId);
                return;
            };
            queueResponseTask(io, allocator, arena, pool, next_request_task, id, task) catch |err| {
                frontend.reportHandlerError(io, arena, app.describe_error, id, err);
            };
        },
        .later => {},
    }
}

//
// Queues the task whose result is a message's response, under the source "request". Its result is sent as the message's response when
// it ends, and a task that fails or is cancelled gives an error response. The number of tasks queued so far names it: a message's own
// id cannot, because the frontend numbers its messages from 1 again when it reloads, while a task of the last page can still be running.
//
fn queueResponseTask(io: std.Io, allocator: std.mem.Allocator, arena: std.mem.Allocator, pool: *worker_pool.WorkerPool, next_request_task: *u64, id: std.json.Value, task: handlers_lib.ResponseTask) !void {
    const id_json = try json.stringify(arena, id);
    const task_id = try std.fmt.allocPrint(arena, "request-{d}", .{next_request_task.*});
    next_request_task.* += 1;
    try pool.addTask(io, allocator, task_id, task.task_type, "request", task.data, .interactive, id_json);
}

//
// What running a system message came to: its response as JSON text, or the InvalidMessageData text of data that did not fit, or no
// system message of that name.
//
const SystemOutcome = union(enum) {
    // The JSON text of the response.
    response: []const u8,
    // How the data did not fit.
    invalid_data: []const u8,
    // There is no system message of the name.
    unknown,
};

//
// Handles a system message: runs Ziggy's function for its name (see system-messages.zig) and sends the response when it carries an id.
// It never reaches the app's handlers. A message with no name is InvalidMessage, and a name Ziggy has no system message of is
// UnknownSystemMessage.
//
fn runSystemMessage(allocator: std.mem.Allocator, arena: std.mem.Allocator, frontend: Frontend, app: RegisteredApp, services: services_lib.HandlerServices, timers: timers_lib.Timers, io: std.Io, pool: *worker_pool.WorkerPool, dropped: *dropped_files.DroppedFiles, tests: *TestCommands, parsed: std.json.Value) void {
    const request_id: ?std.json.Value = parsed.object.get("id");
    const name = messageName(parsed) orelse {
        frontend.reportError(io, arena, request_id, "InvalidMessage");
        return;
    };
    const data = parsed.object.get("data") orelse .null;
    const outcome = runSystem(allocator, arena, name, data, app.menu_targets, services, timers, io, pool, dropped, tests) catch |err| {
        frontend.reportHandlerError(io, arena, app.describe_error, request_id, err);
        return;
    };
    switch (outcome) {
        .response => |text| {
            const id = request_id orelse {
                return;
            };
            frontend.sendResponse(io, arena, id, text) catch |err| {
                frontend.reportError(io, arena, null, @errorName(err));
            };
        },
        .invalid_data => |text| frontend.reportError(io, arena, request_id, text),
        .unknown => frontend.reportError(io, arena, request_id, "UnknownSystemMessage"),
    }
}

//
// Runs the system message of the name with its data, giving its function only the piece of the main thread's state it uses.
//
fn runSystem(allocator: std.mem.Allocator, arena: std.mem.Allocator, name: []const u8, data: std.json.Value, menu_targets: menu_lib.MenuTargets, services: services_lib.HandlerServices, timers: timers_lib.Timers, io: std.Io, pool: *worker_pool.WorkerPool, dropped: *dropped_files.DroppedFiles, tests: *TestCommands) !SystemOutcome {
    if (std.mem.eql(u8, name, "add-task")) {
        const payload = switch (try handlers_lib.parsePayload(system_messages.tasks.AddTaskRequest, arena, data)) {
            .parsed => |value| value,
            .invalid => |text| return .{
                .invalid_data = text,
            },
        };
        return try respond(arena, try system_messages.tasks.addTask(pool, io, allocator, payload));
    }
    if (std.mem.eql(u8, name, "cancel-tasks")) {
        const source = switch (try handlers_lib.parsePayload([]const u8, arena, data)) {
            .parsed => |value| value,
            .invalid => |text| return .{
                .invalid_data = text,
            },
        };
        return try respond(arena, system_messages.tasks.cancelTasks(pool, io, allocator, source));
    }
    if (std.mem.eql(u8, name, "get-platform")) {
        return try respond(arena, system_messages.platform.getPlatform());
    }
    if (std.mem.eql(u8, name, "menu-action")) {
        const payload = switch (try handlers_lib.parsePayload(system_messages.menu.MenuActionRequest, arena, data)) {
            .parsed => |value| value,
            .invalid => |text| return .{
                .invalid_data = text,
            },
        };
        return try respond(arena, try system_messages.menu.menuAction(menu_targets, services, timers, io, arena, payload));
    }
    if (std.mem.eql(u8, name, "get-dropped-paths")) {
        return try respond(arena, try system_messages.dropped_files.getDroppedPaths(dropped, arena));
    }
    if (std.mem.eql(u8, name, "log")) {
        const payload = switch (try handlers_lib.parsePayload(system_messages.log.LogRequest, arena, data)) {
            .parsed => |value| value,
            .invalid => |text| return .{
                .invalid_data = text,
            },
        };
        return try respond(arena, try system_messages.log.log(arena, payload));
    }
    if (build_options.test_hooks) {
        if (std.mem.eql(u8, name, "test-result")) {
            const payload = switch (try handlers_lib.parsePayload(system_messages.test_hooks.TestResultRequest, arena, data)) {
                .parsed => |value| value,
                .invalid => |text| return .{
                    .invalid_data = text,
                },
            };
            return try respond(arena, try system_messages.test_hooks.testResult(tests, io, allocator, timers, payload));
        }
        if (std.mem.eql(u8, name, "test-ui-ready")) {
            return try respond(arena, try system_messages.test_hooks.testUiReady(tests, io, allocator, timers));
        }
    }
    return .unknown;
}

//
// The outcome of a system message that gave the value as its response.
//
fn respond(arena: std.mem.Allocator, value: anytype) !SystemOutcome {
    return .{
        .response = try json.stringify(arena, value),
    };
}
