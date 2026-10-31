//
// A log that keeps what it is given in memory, for a test that checks what was logged: it records the text a console log with the
// same options would write, by stream, and writes nothing.
//

const std = @import("std");
const log = @import("log.zig");
const wrapped_error = @import("utils").wrapped_error;
const ThreadAllocator = @import("utils").thread_allocator.ThreadAllocator;

const ILog = log.ILog;
const ILogLine = log.ILogLine;
const ILogOptions = log.ILogOptions;
const LogLevel = log.LogLevel;

//
// The console stream a line a console log writes would go to.
//
const Stream = enum {
    stdout,
    stderr,
};

//
// The log that keeps its lines in memory. Used by one thread at a time.
//
pub const MemoryLog = struct {
    // Allocates the memory log and the recorded text.
    allocator: std.mem.Allocator,
    // Which lines are recorded, as for a console log.
    options: ILogOptions,
    // What a console log would write to stdout, one line ending in a line feed per line.
    stdout_text: std.ArrayList(u8),
    // What a console log would write to stderr, one line ending in a line feed per line.
    stderr_text: std.ArrayList(u8),
    // The memory log as a log, for code under test that is given one.
    log: ILog,

    //
    // Makes a memory log that records the lines the options turn on. The memory log and its text are allocated with the allocator and
    // freed by deinit.
    //
    pub fn init(allocator: std.mem.Allocator, options: ILogOptions) !*MemoryLog {
        const self = try allocator.create(MemoryLog);
        self.* = .{
            .allocator = allocator,
            .options = options,
            .stdout_text = .empty,
            .stderr_text = .empty,
            .log = .{
                .ptr = self,
                .vtable = &vtable,
            },
        };
        return self;
    }

    //
    // Frees the memory log and its text.
    //
    pub fn deinit(self: *MemoryLog) void {
        self.stdout_text.deinit(self.allocator);
        self.stderr_text.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    //
    // What a console log would have written to stdout.
    //
    pub fn stdout(self: *const MemoryLog) []const u8 {
        return self.stdout_text.items;
    }

    //
    // What a console log would have written to stderr.
    //
    pub fn stderr(self: *const MemoryLog) []const u8 {
        return self.stderr_text.items;
    }

    //
    // Records a line as a console log with the same options would write it: info, verbose, tool and event lines as stdout, error,
    // exception, warn and debug lines as stderr, and verbose, debug and tool lines only when their option is on.
    //
    fn writeLine(self: *MemoryLog, line: ILogLine) void {
        switch (line.level) {
            .info => self.record(.stdout, line.message),
            .verbose => if (self.options.verbose) {
                self.record(.stdout, line.message);
            },
            .@"error", .warn => self.record(.stderr, line.message),
            .exception => {
                self.record(.stderr, line.message);
                if (line.error_text) |text| {
                    if (text.len > 0) {
                        self.record(.stderr, text);
                    }
                }
            },
            .debug => if (self.options.debug) {
                self.record(.stderr, line.message);
            },
            .tool => if (self.options.tools) {
                if (line.tool_output) |output| {
                    self.recordToolStream(line.message, "stdout", output.stdout);
                    self.recordToolStream(line.message, "stderr", output.stderr);
                }
            },
            .event => {
                self.appendText(.stdout, "[EVENT] ");
                self.record(.stdout, line.message);
            },
        }
    }

    //
    // Records `== <tool> <stream> ==` and what the tool wrote to it, when it wrote anything.
    //
    fn recordToolStream(self: *MemoryLog, tool_name: []const u8, stream: []const u8, text: ?[]const u8) void {
        const written = text orelse return;
        if (written.len == 0) {
            return;
        }
        self.appendText(.stdout, "== ");
        self.appendText(.stdout, tool_name);
        self.appendText(.stdout, " ");
        self.appendText(.stdout, stream);
        self.appendText(.stdout, " ==\n");
        self.record(.stdout, written);
    }

    //
    // Records one console line of the stream, with its line ending.
    //
    fn record(self: *MemoryLog, stream: Stream, text: []const u8) void {
        self.appendText(stream, text);
        self.appendText(stream, "\n");
    }

    //
    // Adds text to what the stream holds.
    //
    fn appendText(self: *MemoryLog, stream: Stream, text: []const u8) void {
        const target = switch (stream) {
            .stdout => &self.stdout_text,
            .stderr => &self.stderr_text,
        };
        target.appendSlice(self.allocator, text) catch @panic("out of memory recording a log line");
    }

    //
    // The ILog functions of the memory log.
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
        .logFilePath = logFilePath,
    };

    //
    // Records a line of the level.
    //
    fn writeOwn(ptr: *anyopaque, level: LogLevel, message: []const u8) void {
        const self: *MemoryLog = @ptrCast(@alignCast(ptr));
        self.writeLine(.{
            .level = level,
            .message = message,
            .error_text = null,
            .tool_output = null,
        });
    }

    fn info(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .info, message);
    }

    fn verbose(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .verbose, message);
    }

    fn logError(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .@"error", message);
    }

    fn warn(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .warn, message);
    }

    fn debug(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .debug, message);
    }

    fn event(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .event, message);
    }

    //
    // Records a line and the error's cause chain.
    //
    fn exception(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        const self: *MemoryLog = @ptrCast(@alignCast(ptr));
        // A log function is given no allocator, so the chain is built with one made for the call.
        var thread_allocator: ThreadAllocator = .init;
        defer thread_allocator.deinit();
        var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
        defer arena_state.deinit();
        const chain = wrapped_error.formatErrorChain(arena_state.allocator(), err) catch @panic("out of memory recording an error");
        self.writeLine(.{
            .level = .exception,
            .message = message,
            .error_text = chain,
            .tool_output = null,
        });
    }

    //
    // Records what a tool wrote.
    //
    fn tool(ptr: *anyopaque, toolName: []const u8, data: log.IToolOutput) void {
        const self: *MemoryLog = @ptrCast(@alignCast(ptr));
        self.writeLine(.{
            .level = .tool,
            .message = toolName,
            .error_text = null,
            .tool_output = data,
        });
    }

    fn verboseEnabled(ptr: *anyopaque) bool {
        const self: *MemoryLog = @ptrCast(@alignCast(ptr));
        return self.options.verbose;
    }

    //
    // A memory log writes no log file.
    //
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!log.ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return log.noLogDetails;
    }

    fn logFilePath(ptr: *anyopaque) ?[]const u8 {
        _ = ptr;
        return null;
    }
};
