//
// The handler services: what the app's message handlers, menu item functions and callbacks (on_create, on_destroy, on_task_end,
// on_task_event, ui_query) reach the main thread through. It is an interface, as `std.Io` is, and hides how the main thread keeps its
// state. Each call runs on the main thread, where every handler runs, and is carried out before it returns, except addTask and
// cancelTasks, which the main thread carries out once the handler has returned, in the order they were made. Each call that needs the
// main thread's Io or allocator is given them by the handler, which was given them with the services. A task's handler reaches the
// main thread through the task services instead (see task-runner.zig).
//

const std = @import("std");
const task_runner = @import("task-runner.zig");
const types = @import("types.zig");
const json = @import("json.zig");
const native_caller = @import("utils").native_caller;
const errors = @import("utils").errors;
const native_app = @import("native-app.zig");
const worker_messages = @import("worker-messages.zig");
const MessageQueue = @import("message-queue.zig").MessageQueue;
const ILog = @import("log").ILog;
const ILogOptions = @import("log").ILogOptions;

//
// How a thread of the app's own (a server, for one) reaches the native app itself: by sending the frontend an event and by native
// calls, each posted to the native app's queue (see native-app.zig). The thread is given a copy, so it needs nothing of the main
// thread's. A copy is valid until the main thread has called the app's on_destroy with `.before_tasks_stop`, by when the app has
// stopped its own threads.
//
pub const NativeCallbacks = struct {
    // The native app's queue and how to wake its UI thread.
    native: native_app.NativeApp,
    // Whether the native app does native calls (see ZiggyConfig.has_native_call).
    has_native_call: bool,

    //
    // Sends the frontend an event of the app's own, whose data is the JSON text data_json, as HandlerServices.sendEvent does. The Io
    // and the allocator are the calling thread's own, and the allocator is used only during the call.
    //
    pub fn sendEvent(self: NativeCallbacks, io: std.Io, allocator: std.mem.Allocator, data_json: []const u8) !void {
        const event = try json.stringify(allocator, .{
            .kind = "app",
            .data = json.Raw{
                .text = data_json,
            },
        });
        defer allocator.free(event);
        try self.native.deliver(io, event);
    }

    //
    // The native caller that makes native calls through the native app for the calling thread, or null when the native app does
    // none. It is valid as long as this value is.
    //
    pub fn nativeCaller(self: *const NativeCallbacks) ?native_caller.INativeCaller {
        if (!self.has_native_call) {
            return null;
        }
        return .{
            .ptr = @constCast(self),
            .request = request,
        };
    }

    //
    // Has the native app do what the method names, waiting on a queue of the calling thread's own for the result, and returns the
    // result, allocated with the allocator. The Io and the allocator are the calling thread's own. A result that did not succeed is
    // an error with the native app's reason in it.
    //
    fn request(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) anyerror![]const u8 {
        const self: *const NativeCallbacks = @ptrCast(@alignCast(ptr));
        var replies = MessageQueue.init();
        defer replies.deinit();
        try self.native.call(io, allocator, .{
            .native_call = .{
                .method = method,
                .request = request_json,
            },
        }, .{
            .queue = &replies,
            .call_id = 0,
        });
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const reply = replies.take(io, arena, .none) orelse {
            @panic("the queue of a native call's result closed");
        };
        const response = try worker_messages.decode(worker_messages.INativeAppResponseMessage, arena, reply.text);
        if (response.@"error") |reason| {
            return errors.throwError("{s} failed: {s}", .{ method, reason });
        }
        const result = response.result orelse .null;
        if (result != .string) {
            return error.InvalidNativeAppResponse;
        }
        return try allocator.dupe(u8, result.string);
    }
};

//
// The handler services. It is a small value that may be copied and kept, for a timer's callback for one, and it is valid on the main thread
// until the main thread has called the app's on_destroy for the last time.
//
pub const HandlerServices = struct {
    // The implementation's own pointer, passed back on every call.
    ptr: *anyopaque,
    // The implementation's functions.
    vtable: *const VTable,
    // The main thread's log, which a handler, a menu item's function or an app function writes to: the app's file log for the whole run,
    // or the console log for an app without one.
    log: ILog,

    //
    // The functions behind the interface.
    //
    pub const VTable = struct {
        sendEvent: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, data_json: []const u8) anyerror!void,
        addTask: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, task_id: []const u8, task_type: []const u8, source: []const u8, data_json: []const u8, priority: task_runner.TaskPriority) anyerror!void,
        cancelTasks: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, source: []const u8) void,
        holdKeepAlive: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, keep_running: bool) void,
        quit: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void,
        menuAction: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, action: []const u8) void,
        dataDir: *const fn (ptr: *anyopaque) []const u8,
        isPhone: *const fn (ptr: *anyopaque) bool,
        nativeCallbacks: *const fn (ptr: *anyopaque) NativeCallbacks,
        configureLog: *const fn (ptr: *anyopaque, options: ILogOptions) anyerror!void,
    };

    //
    // The native app's callbacks that a thread of the app's own may call itself (see NativeCallbacks), copied for that thread.
    //
    pub fn nativeCallbacks(self: HandlerServices) NativeCallbacks {
        return self.vtable.nativeCallbacks(self.ptr);
    }

    //
    // Sends the frontend an event of the app's own, whose data is the JSON text data_json, which the frontend's onEvent listeners
    // receive. The allocator is used only during the call.
    //
    pub fn sendEvent(self: HandlerServices, io: std.Io, allocator: std.mem.Allocator, data_json: []const u8) !void {
        try self.vtable.sendEvent(self.ptr, io, allocator, data_json);
    }

    //
    // Queues a task of the type, with the id, the source it is cancelled by and the JSON text of its input, once the handler has
    // returned. The strings are copied.
    //
    pub fn addTask(self: HandlerServices, io: std.Io, allocator: std.mem.Allocator, task_id: []const u8, task_type: []const u8, source: []const u8, data_json: []const u8, priority: task_runner.TaskPriority) !void {
        try self.vtable.addTask(self.ptr, io, allocator, task_id, task_type, source, data_json, priority);
    }

    //
    // Cancels every task queued under the source, once the handler has returned and the tasks it added before are queued.
    //
    pub fn cancelTasks(self: HandlerServices, io: std.Io, allocator: std.mem.Allocator, source: []const u8) void {
        self.vtable.cancelTasks(self.ptr, io, allocator, source);
    }

    //
    // Keeps the app running, with or without a task, until it is called with false: through the native app's keep_alive callback.
    //
    pub fn holdKeepAlive(self: HandlerServices, io: std.Io, allocator: std.mem.Allocator, keep_running: bool) void {
        self.vtable.holdKeepAlive(self.ptr, io, allocator, keep_running);
    }

    //
    // Has the native app quit, through its quit callback. A native app with none ignores it.
    //
    pub fn quit(self: HandlerServices, io: std.Io, allocator: std.mem.Allocator) void {
        self.vtable.quit(self.ptr, io, allocator);
    }

    //
    // Has the native app run one of its own menu actions by name, such as "focus-window" or "toggle-devtools", through its menu_action
    // callback. A native app with none ignores it.
    //
    pub fn menuAction(self: HandlerServices, io: std.Io, allocator: std.mem.Allocator, action: []const u8) void {
        self.vtable.menuAction(self.ptr, io, allocator, action);
    }

    //
    // The app's private data directory, which the native app chose. Valid for as long as the main thread runs.
    //
    pub fn dataDir(self: HandlerServices) []const u8 {
        return self.vtable.dataDir(self.ptr);
    }

    //
    // Whether the native app is a phone's: the native apps of Android and iOS give the core a native call callback, which no desktop
    // native app has.
    //
    pub fn isPhone(self: HandlerServices) bool {
        return self.vtable.isPhone(self.ptr);
    }

    //
    // Sets which lines the main thread's log shows on the console, from the options the app read from its own arguments. Optional: a
    // log never configured shows no verbose, debug or tool lines. The log file gets every line either way. An app calls it once, as
    // early as it can, which is its `on_create`; a second call fails with error.LogAlreadyConfigured.
    //
    pub fn configureLog(self: HandlerServices, options: ILogOptions) !void {
        try self.vtable.configureLog(self.ptr, options);
    }
};

//
// The handler services a timer's callback on the main thread is given, as its `services` (see `ziggy.timers.TimerCallback`).
//
pub fn handlerServicesOf(services: ?*const anyopaque) HandlerServices {
    const given: *const HandlerServices = @ptrCast(@alignCast(services orelse {
        @panic("a timer's callback on the main thread was given no handler services");
    }));
    return given.*;
}
