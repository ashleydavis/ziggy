//
// The log of a worker (ILog): it sends each line to the main thread as an IWorkerLogMessage, as worker-log-electron.ts does in
// TypeScript, because only the main thread writes stdout, stderr and log files. A worker logs through one, numbered with its id. The
// main thread writes what it is sent to its own log (see `worker_pool.writeLog` and `worker_pool.writeConsole`).
//

const std = @import("std");
const message_queue = @import("message-queue.zig");
const worker_messages = @import("worker-messages.zig");

const MessageQueue = message_queue.MessageQueue;
const ThreadAllocator = @import("utils").thread_allocator.ThreadAllocator;
const utils = @import("utils");
const ziggy_log = @import("log");

//
// A thread's log that sends its lines to the main thread's queue.
//
pub const QueueLog = struct {
    // The main thread's queue.
    queue: *MessageQueue,
    // The number the lines reach the main thread's queue under.
    from: u32,
    // When true, verbose lines are sent.
    verbose_enabled: bool,
    // When true, the output of tools is sent.
    tools_enabled: bool,

    //
    // Gets the ILog interface for this log.
    //
    pub fn ilog(self: *QueueLog) ziggy_log.log.ILog {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // Has the calling thread's console lines sent to the main thread through this log's queue. The log must stay
    // where it is until `unset` is called on the same thread.
    //
    pub fn set(self: *QueueLog) void {
        ziggy_log.console.setForward(.{
            .context = self,
            .function = forwardConsole,
        });
    }

    //
    // Has the calling thread use its own console again.
    //
    pub fn unset() void {
        ziggy_log.console.setForward(null);
    }

    //
    // The ILog functions of this log.
    //
    const vtable: ziggy_log.log.ILog.VTable = .{
        .info = info,
        .verbose = verbose,
        .@"error" = logError,
        .exception = exception,
        .warn = warn,
        .debug = debug,
        .tool = tool,
        .event = event,
        .verboseEnabled = verboseEnabled,
        .getLogDetails = getLogDetails,
        .logFilePath = logFilePath,
    };

    //
    // Sends one line to the main thread. The ILog functions are given no Io, so the post uses one of the calling thread's own, made for
    // the call.
    //
    pub fn send(self: *QueueLog, level: worker_messages.LogLevel, message: []const u8, error_text: ?[]const u8, tool_data: ?worker_messages.IToolData) void {
        // The ILog functions are given no allocator either, so the line is built with an allocator made for the call.
        var thread_allocator: ThreadAllocator = .init;
        defer thread_allocator.deinit();
        var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
        defer arena_state.deinit();
        const text = worker_messages.encode(arena_state.allocator(), worker_messages.IWorkerLogMessage{
            .level = level,
            .message = message,
            .@"error" = error_text,
            .toolData = tool_data,
        }) catch @panic("out of memory sending a log line");
        var threaded: std.Io.Threaded = .init_single_threaded;
        threaded.allocator = arena_state.allocator();
        defer threaded.deinit();
        self.queue.post(threaded.io(), self.from, text) catch @panic("out of memory sending a log line");
    }

    //
    // Sends an informational line.
    //
    fn info(ptr: *anyopaque, message: []const u8) void {
        const self: *QueueLog = @ptrCast(@alignCast(ptr));
        self.send(.info, message, null, null);
    }

    //
    // Sends a verbose line, when verbose lines are on.
    //
    fn verbose(ptr: *anyopaque, message: []const u8) void {
        const self: *QueueLog = @ptrCast(@alignCast(ptr));
        if (self.verbose_enabled) {
            self.send(.verbose, message, null, null);
        }
    }

    //
    // Sends an error line.
    //
    fn logError(ptr: *anyopaque, message: []const u8) void {
        const self: *QueueLog = @ptrCast(@alignCast(ptr));
        self.send(.@"error", message, null, null);
    }

    //
    // Sends a line and the error with what caused it.
    //
    fn exception(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        const self: *QueueLog = @ptrCast(@alignCast(ptr));
        var buffer: [16 * 1024]u8 = undefined;
        var fixed_writer = std.Io.Writer.fixed(&buffer);
        utils.wrapped_error.writeErrorChain(&fixed_writer, err) catch {};
        self.send(.exception, message, fixed_writer.buffered(), null);
    }

    //
    // Sends a warning line.
    //
    fn warn(ptr: *anyopaque, message: []const u8) void {
        const self: *QueueLog = @ptrCast(@alignCast(ptr));
        self.send(.warn, message, null, null);
    }

    //
    // Sends a debug line.
    //
    fn debug(ptr: *anyopaque, message: []const u8) void {
        const self: *QueueLog = @ptrCast(@alignCast(ptr));
        self.send(.debug, message, null, null);
    }

    //
    // Sends what a tool wrote, when the output of tools is on.
    //
    fn tool(ptr: *anyopaque, tool_name: []const u8, data: ziggy_log.log.IToolOutput) void {
        const self: *QueueLog = @ptrCast(@alignCast(ptr));
        if (self.tools_enabled) {
            self.send(.tool, tool_name, null, .{
                .stdout = data.stdout,
                .stderr = data.stderr,
            });
        }
    }

    //
    // Sends an event line.
    //
    fn event(ptr: *anyopaque, message: []const u8) void {
        const self: *QueueLog = @ptrCast(@alignCast(ptr));
        self.send(.event, message, null, null);
    }

    //
    // Whether verbose lines are sent.
    //
    fn verboseEnabled(ptr: *anyopaque) bool {
        const self: *QueueLog = @ptrCast(@alignCast(ptr));
        return self.verbose_enabled;
    }

    //
    // A thread's log has no log file of its own.
    //
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!ziggy_log.log.ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return ziggy_log.log.noLogDetails;
    }

    //
    // A thread's log writes no log file of its own.
    //
    fn logFilePath(ptr: *anyopaque) ?[]const u8 {
        _ = ptr;
        return null;
    }

    //
    // Where the thread's console lines go: the main thread, stdout's and stderr's each on its own stream. The post uses an Io of the
    // calling thread's own, made for the call.
    //
    pub fn forwardConsole(context: ?*anyopaque, stream: ziggy_log.console.Stream, line: []const u8) void {
        const self: *QueueLog = @ptrCast(@alignCast(context.?));
        // The ILog functions are given no allocator either, so the line is built with an allocator made for the call.
        var thread_allocator: ThreadAllocator = .init;
        defer thread_allocator.deinit();
        var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
        defer arena_state.deinit();
        const text = worker_messages.encode(arena_state.allocator(), worker_messages.IWorkerConsoleMessage{
            .stream = @tagName(stream),
            .line = line,
        }) catch @panic("out of memory sending a console line");
        var threaded: std.Io.Threaded = .init_single_threaded;
        threaded.allocator = arena_state.allocator();
        defer threaded.deinit();
        self.queue.post(threaded.io(), self.from, text) catch @panic("out of memory sending a console line");
    }
};
