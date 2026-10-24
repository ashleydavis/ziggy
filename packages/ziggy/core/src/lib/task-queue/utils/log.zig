const std = @import("std");
const console = @import("console.zig");
const wrapped_error = @import("wrapped-error.zig");

//
// Details about the active log file, used to pre-fill bug reports.
//
pub const ILogDetails = struct {
    // Full path to the active log file, or null when file logging is not active.
    logFilePath: ?[]const u8,

    // The header section of the active log file (system information), or a placeholder when unavailable.
    logHeader: []const u8,
};

//
// Log details placeholder for log implementations that do not write to a log file.
//
pub const noLogDetails: ILogDetails = .{
    .logFilePath = null,
    .logHeader = "No log file available",
};

//
// The output of an external tool passed to ILog.tool.
//
pub const IToolOutput = struct {
    // The standard output of the tool, if any.
    stdout: ?[]const u8,

    // The standard error of the tool, if any.
    stderr: ?[]const u8,
};

//
// The interface implemented by every log.
//
pub const ILog = struct {
    // The log implementation.
    ptr: *anyopaque,

    // The functions of the log implementation.
    vtable: *const VTable,

    //
    // The functions a log implementation provides.
    //
    pub const VTable = struct {
        // Logs an informational message.
        info: *const fn (ptr: *anyopaque, message: []const u8) void,

        // Logs a verbose message.
        verbose: *const fn (ptr: *anyopaque, message: []const u8) void,

        // Logs an error message.
        @"error": *const fn (ptr: *anyopaque, message: []const u8) void,

        // Logs a message and an error with its cause chain.
        exception: *const fn (ptr: *anyopaque, message: []const u8, err: anyerror) void,

        // Logs a warning message.
        warn: *const fn (ptr: *anyopaque, message: []const u8) void,

        // Logs a debug message.
        debug: *const fn (ptr: *anyopaque, message: []const u8) void,

        // Logs the output of an external tool.
        tool: *const fn (ptr: *anyopaque, tool: []const u8, data: IToolOutput) void,

        // Logs an event.
        event: *const fn (ptr: *anyopaque, message: []const u8) void,

        // Returns true when verbose logging is enabled.
        verboseEnabled: *const fn (ptr: *anyopaque) bool,

        // Gets details about the active log file for inclusion in bug reports.
        getLogDetails: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!ILogDetails,
    };

    //
    // Logs an informational message.
    //
    pub fn info(self: ILog, message: []const u8) void {
        self.vtable.info(self.ptr, message);
    }

    //
    // Logs a verbose message.
    //
    pub fn verbose(self: ILog, message: []const u8) void {
        self.vtable.verbose(self.ptr, message);
    }

    //
    // Logs an error message.
    //
    pub fn @"error"(self: ILog, message: []const u8) void {
        self.vtable.@"error"(self.ptr, message);
    }

    //
    // Logs a message and an error with its cause chain.
    //
    pub fn exception(self: ILog, message: []const u8, err: anyerror) void {
        self.vtable.exception(self.ptr, message, err);
    }

    //
    // Logs a warning message.
    //
    pub fn warn(self: ILog, message: []const u8) void {
        self.vtable.warn(self.ptr, message);
    }

    //
    // Logs a debug message.
    //
    pub fn debug(self: ILog, message: []const u8) void {
        self.vtable.debug(self.ptr, message);
    }

    //
    // Logs the output of an external tool.
    //
    pub fn tool(self: ILog, toolName: []const u8, data: IToolOutput) void {
        self.vtable.tool(self.ptr, toolName, data);
    }

    //
    // Logs an event.
    //
    pub fn event(self: ILog, message: []const u8) void {
        self.vtable.event(self.ptr, message);
    }

    //
    // Returns true when verbose logging is enabled.
    //
    pub fn verboseEnabled(self: ILog) bool {
        return self.vtable.verboseEnabled(self.ptr);
    }

    //
    // Gets details about the active log file for inclusion in bug reports.
    //
    pub fn getLogDetails(self: ILog, allocator: std.mem.Allocator, io: std.Io) anyerror!ILogDetails {
        return self.vtable.getLogDetails(self.ptr, allocator, io);
    }
};

//
// Sets the log of the calling thread, or, with null, has it use the console log again. Each thread has its own: the main thread's
// writes to the console or a file, and a worker's sends each line to the main thread (see worker.zig in Ziggy's core).
//
pub fn setLog(_log: ?ILog) void {
    thread_log = _log;
}

//
// The log of the calling thread: the one it set with setLog, or the console log.
//
pub fn currentLog() ILog {
    return thread_log orelse .{
        .ptr = @constCast(&console_log),
        .vtable = &ConsoleLog.vtable,
    };
}

//
// The default log, which writes to the console.
//
pub const ConsoleLog = struct {
    // True when verbose logging is enabled (always false for the console log).
    verbose_enabled: bool,

    //
    // Gets the ILog interface for this log.
    //
    pub fn ilog(self: *ConsoleLog) ILog {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The ILog functions of the console log.
    //
    const vtable: ILog.VTable = .{
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
    };

    //
    // Writes an informational message to stdout.
    //
    fn info(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        console.log(message);
    }

    //
    // You have to override this method if you want to use it.
    //
    fn verbose(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        _ = message;
    }

    //
    // Writes an error message to stderr.
    //
    fn logError(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        console.@"error"(message);
    }

    //
    // Writes a message and the error's cause chain to stderr.
    //
    fn exception(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        _ = ptr;
        console.@"error"(message);
        var buffer: [16 * 1024]u8 = undefined;
        var fixed_writer = std.Io.Writer.fixed(&buffer);
        wrapped_error.writeErrorChain(&fixed_writer, err) catch {};
        console.@"error"(fixed_writer.buffered());
    }

    //
    // Writes a warning message to stderr.
    //
    fn warn(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        console.warn(message);
    }

    //
    // Writes a debug message to stdout.
    //
    fn debug(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        console.debug(message);
    }

    //
    // You have to override this method if you want to use it.
    //
    fn tool(ptr: *anyopaque, toolName: []const u8, data: IToolOutput) void {
        _ = ptr;
        _ = toolName;
        _ = data;
    }

    //
    // Writes an event to stdout.
    //
    fn event(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        console.logFormat("[EVENT] {s}", .{message});
    }

    //
    // Returns true when verbose logging is enabled.
    //
    fn verboseEnabled(ptr: *anyopaque) bool {
        const self: *ConsoleLog = @ptrCast(@alignCast(ptr));
        return self.verbose_enabled;
    }

    //
    // The console log does not write to a log file.
    //
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return noLogDetails;
    }
};

//
// State of the default console log, which nothing changes.
//
const console_log: ConsoleLog = .{ .verbose_enabled = false };

//
// The log of the calling thread, set with setLog, or null for the console log.
//
threadlocal var thread_log: ?ILog = null;

//
// The log every caller writes to. It holds nothing of its own: each line goes to the log of the thread that writes it (currentLog).
//
pub const log: ILog = .{
    .ptr = @constCast(&console_log),
    .vtable = &ThreadLog.vtable,
};

//
// The functions of `log`, each of which passes the call on to the calling thread's log.
//
const ThreadLog = struct {
    const vtable: ILog.VTable = .{
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
    };

    fn info(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        currentLog().info(message);
    }

    fn verbose(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        currentLog().verbose(message);
    }

    fn logError(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        currentLog().@"error"(message);
    }

    fn exception(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        _ = ptr;
        currentLog().exception(message, err);
    }

    fn warn(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        currentLog().warn(message);
    }

    fn debug(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        currentLog().debug(message);
    }

    fn tool(ptr: *anyopaque, toolName: []const u8, data: IToolOutput) void {
        _ = ptr;
        currentLog().tool(toolName, data);
    }

    fn event(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        currentLog().event(message);
    }

    fn verboseEnabled(ptr: *anyopaque) bool {
        _ = ptr;
        return currentLog().verboseEnabled();
    }

    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!ILogDetails {
        _ = ptr;
        return currentLog().getLogDetails(allocator, io);
    }
};
