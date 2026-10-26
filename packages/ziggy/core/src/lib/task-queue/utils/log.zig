const std = @import("std");
const console = @import("console.zig");
const wrapped_error = @import("wrapped-error.zig");
const ThreadAllocator = @import("../../thread-allocator.zig").ThreadAllocator;

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
// The level of a log line.
//
pub const LogLevel = enum {
    info,
    verbose,
    @"error",
    exception,
    warn,
    debug,
    tool,
    event,
};

//
// A log line that came from somewhere other than the thread writing it (a worker or the frontend), as the main thread writes it.
//
pub const ILogLine = struct {
    // The level of the line.
    level: LogLevel,
    // The line, or for the tool level the name of the tool.
    message: []const u8,
    // For the exception level, the error and what caused it, or null.
    error_text: ?[]const u8,
    // For the tool level, what the tool wrote, or null.
    tool_output: ?IToolOutput,
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
// The log that writes to the console. Info, verbose, tool and event lines go to stdout, error, exception, warn and debug lines to
// stderr. Verbose, debug and tool lines are written only when their option is on.
//
pub const ConsoleLog = struct {
    // When true, verbose lines are written.
    verbose_enabled: bool,
    // When true, debug lines are written.
    debug_enabled: bool,
    // When true, the output of tools is written.
    tools_enabled: bool,

    //
    // Gets the ILog interface for this log.
    //
    pub fn ilog(self: *ConsoleLog) ILog {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The console log behind an ILog, or null when the ILog is some other log.
    //
    pub fn fromILog(log_to_check: ILog) ?*const ConsoleLog {
        if (log_to_check.vtable != &vtable) {
            return null;
        }
        return @ptrCast(@alignCast(log_to_check.ptr));
    }

    //
    // Writes a line, prefixed with `[source]` when a source is given, to the stream its level goes to, when its option is on.
    //
    pub fn writeLine(self: *const ConsoleLog, source: ?[]const u8, line: ILogLine) void {
        // A log function is given no allocator, so the line is built with one made for the call.
        var thread_allocator: ThreadAllocator = .init;
        defer thread_allocator.deinit();
        var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        switch (line.level) {
            .info => console.log(prefixed(arena, source, line.message)),
            .verbose => if (self.verbose_enabled) {
                console.log(prefixed(arena, source, line.message));
            },
            .@"error" => console.@"error"(prefixed(arena, source, line.message)),
            .exception => {
                console.@"error"(prefixed(arena, source, line.message));
                if (line.error_text) |text| {
                    if (text.len > 0) {
                        console.@"error"(text);
                    }
                }
            },
            .warn => console.warn(prefixed(arena, source, line.message)),
            .debug => if (self.debug_enabled) {
                console.@"error"(prefixed(arena, source, line.message));
            },
            .tool => if (self.tools_enabled) {
                if (line.tool_output) |output| {
                    writeToolStream(arena, source, line.message, "stdout", output.stdout);
                    writeToolStream(arena, source, line.message, "stderr", output.stderr);
                }
            },
            .event => console.log(prefixed(arena, source, std.fmt.allocPrint(arena, "[EVENT] {s}", .{line.message}) catch @panic("out of memory writing a log line"))),
        }
    }

    //
    // Writes `== <tool> <stream> ==` and what the tool wrote to it, when it wrote anything.
    //
    fn writeToolStream(arena: std.mem.Allocator, source: ?[]const u8, tool_name: []const u8, stream: []const u8, text: ?[]const u8) void {
        const written = text orelse return;
        if (written.len == 0) {
            return;
        }
        console.log(prefixed(arena, source, std.fmt.allocPrint(arena, "== {s} {s} ==\n{s}", .{ tool_name, stream, written }) catch @panic("out of memory writing a log line")));
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
    // Writes a line the calling thread logged, which has no source.
    //
    fn writeOwn(ptr: *anyopaque, level: LogLevel, message: []const u8) void {
        const self: *const ConsoleLog = @ptrCast(@alignCast(ptr));
        self.writeLine(null, .{
            .level = level,
            .message = message,
            .error_text = null,
            .tool_output = null,
        });
    }

    //
    // Writes an informational line to stdout.
    //
    fn info(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .info, message);
    }

    //
    // Writes a verbose line to stdout, when verbose lines are on.
    //
    fn verbose(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .verbose, message);
    }

    //
    // Writes an error line to stderr.
    //
    fn logError(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .@"error", message);
    }

    //
    // Writes a line and the error's cause chain to stderr.
    //
    fn exception(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        const self: *const ConsoleLog = @ptrCast(@alignCast(ptr));
        // A log function is given no allocator, so the chain, however long, is written with one made for the call.
        var thread_allocator: ThreadAllocator = .init;
        defer thread_allocator.deinit();
        var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
        defer arena_state.deinit();
        const chain = wrapped_error.formatErrorChain(arena_state.allocator(), err) catch @panic("out of memory writing an error");
        self.writeLine(null, .{
            .level = .exception,
            .message = message,
            .error_text = chain,
            .tool_output = null,
        });
    }

    //
    // Writes a warning line to stderr.
    //
    fn warn(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .warn, message);
    }

    //
    // Writes a debug line to stderr, when debug lines are on.
    //
    fn debug(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .debug, message);
    }

    //
    // Writes what a tool wrote to stdout, when the output of tools is on.
    //
    fn tool(ptr: *anyopaque, toolName: []const u8, data: IToolOutput) void {
        const self: *const ConsoleLog = @ptrCast(@alignCast(ptr));
        self.writeLine(null, .{
            .level = .tool,
            .message = toolName,
            .error_text = null,
            .tool_output = data,
        });
    }

    //
    // Writes an event to stdout.
    //
    fn event(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .event, message);
    }

    //
    // Returns true when verbose lines are written.
    //
    fn verboseEnabled(ptr: *anyopaque) bool {
        const self: *const ConsoleLog = @ptrCast(@alignCast(ptr));
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
// The line with `[source] ` in front of it when there is a source.
//
fn prefixed(arena: std.mem.Allocator, source: ?[]const u8, message: []const u8) []const u8 {
    const source_text = source orelse return message;
    return std.fmt.allocPrint(arena, "[{s}] {s}", .{ source_text, message }) catch @panic("out of memory writing a log line");
}

//
// State of the default console log, which nothing changes: every option is off.
//
const console_log: ConsoleLog = .{
    .verbose_enabled = false,
    .debug_enabled = false,
    .tools_enabled = false,
};

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
