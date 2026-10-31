const std = @import("std");
const utils = @import("utils");
const MuteLog = @import("log").mute_log.MuteLog;
const ILog = @import("log").ILog;
const ILogDetails = @import("log").ILogDetails;
const IToolOutput = @import("log").IToolOutput;
const ConsoleLog = @import("log").ConsoleLog;
const noLogDetails = @import("log").noLogDetails;
const errors = utils.errors;
const console = @import("log").console;

//
// A log that records the last message it received.
//
const RecordingLog = struct {
    // The last message received by any method.
    lastMessage: []const u8 = "",

    // The name of the method that received the last message.
    lastMethod: []const u8 = "",

    // The name of the last error passed to exception.
    lastErrorName: []const u8 = "",

    //
    // Gets the ILog interface for this log.
    //
    fn ilog(self: *RecordingLog) ILog {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The ILog functions of this log.
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
    // Records a message.
    //
    fn record(ptr: *anyopaque, method: []const u8, message: []const u8) void {
        const self: *RecordingLog = @ptrCast(@alignCast(ptr));
        self.lastMethod = method;
        self.lastMessage = message;
    }

    //
    // Records an info message.
    //
    fn info(ptr: *anyopaque, message: []const u8) void {
        record(ptr, "info", message);
    }

    //
    // Records a verbose message.
    //
    fn verbose(ptr: *anyopaque, message: []const u8) void {
        record(ptr, "verbose", message);
    }

    //
    // Records an error message.
    //
    fn logError(ptr: *anyopaque, message: []const u8) void {
        record(ptr, "error", message);
    }

    //
    // Records an exception message.
    //
    fn exception(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        record(ptr, "exception", message);
        const self: *RecordingLog = @ptrCast(@alignCast(ptr));
        self.lastErrorName = @errorName(err);
    }

    //
    // Records a warning message.
    //
    fn warn(ptr: *anyopaque, message: []const u8) void {
        record(ptr, "warn", message);
    }

    //
    // Records a debug message.
    //
    fn debug(ptr: *anyopaque, message: []const u8) void {
        record(ptr, "debug", message);
    }

    //
    // Records tool output.
    //
    fn tool(ptr: *anyopaque, toolName: []const u8, data: IToolOutput) void {
        _ = data;
        record(ptr, "tool", toolName);
    }

    //
    // Records an event.
    //
    fn event(ptr: *anyopaque, message: []const u8) void {
        record(ptr, "event", message);
    }

    //
    // Verbose logging is always enabled for this log.
    //
    fn verboseEnabled(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    //
    // Returns fixed log details.
    //
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return .{ .logFilePath = "/tmp/test.log", .logHeader = "header" };
    }

    //
    // The path of the log file it pretends to write.
    //
    fn logFilePath(ptr: *anyopaque) ?[]const u8 {
        _ = ptr;
        return "/tmp/test.log";
    }
};

//
// Throws an error with the message "root cause".
//
fn throwRootCause() errors.ThrownError!void {
    return errors.throwError("root cause", .{});
}

test "a console log with no options writes info and event to stdout, error, warn and exception to stderr and leaves out verbose, debug and tool lines" {
    var stdout_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr_capture.deinit();
    console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer console.setCapture(null, null);

    const log = ConsoleLog.init();
    log.info("info message");
    log.verbose("verbose message");
    log.debug("debug message");
    log.event("something happened");
    log.tool("some-tool", .{ .stdout = "out", .stderr = null });
    log.@"error"("error message");
    log.warn("warn message");
    throwRootCause() catch |err| {
        log.exception("Failed.", err);
    };

    try std.testing.expectEqualStrings("info message\n[EVENT] something happened\n", stdout_capture.written());
    try std.testing.expectEqualStrings("error message\nwarn message\nFailed.\nError: root cause\n", stderr_capture.written());
    try std.testing.expect(!log.verboseEnabled());
}

test "a console log has no log details" {
    const console_log = MuteLog.init();
    const details = try console_log.getLogDetails(std.testing.allocator, std.testing.io);
    try std.testing.expect(details.logFilePath == null);
    try std.testing.expectEqualStrings("No log file available", details.logHeader);
    try std.testing.expectEqualStrings(noLogDetails.logHeader, details.logHeader);
}

test "an ILog passes each call to the log it was made from" {
    var recording: RecordingLog = .{};
    const log = recording.ilog();

    log.info("a");
    try std.testing.expectEqualStrings("info", recording.lastMethod);
    log.verbose("b");
    try std.testing.expectEqualStrings("verbose", recording.lastMethod);
    log.@"error"("c");
    try std.testing.expectEqualStrings("error", recording.lastMethod);
    log.exception("d", error.FileNotFound);
    try std.testing.expectEqualStrings("exception", recording.lastMethod);
    try std.testing.expectEqualStrings("FileNotFound", recording.lastErrorName);
    log.warn("e");
    try std.testing.expectEqualStrings("warn", recording.lastMethod);
    log.debug("f");
    try std.testing.expectEqualStrings("debug", recording.lastMethod);
    log.tool("g", .{ .stdout = null, .stderr = null });
    try std.testing.expectEqualStrings("tool", recording.lastMethod);
    log.event("h");
    try std.testing.expectEqualStrings("event", recording.lastMethod);
    try std.testing.expectEqualStrings("h", recording.lastMessage);
    try std.testing.expect(log.verboseEnabled());
    const details = try log.getLogDetails(std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("/tmp/test.log", details.logFilePath.?);
    try std.testing.expectEqualStrings("/tmp/test.log", log.logFilePath().?);
}

test "a console log writes no file" {
    const console_log = MuteLog.init();
    try std.testing.expect(console_log.logFilePath() == null);
}

test "ilog of a console log gives a log that writes to the console" {
    var stdout_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout_capture.deinit();
    console.setCapture(&stdout_capture.writer, null);
    defer console.setCapture(null, null);
    const log = ConsoleLog.initWith(.{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    log.info("from ilog");
    try std.testing.expectEqualStrings("from ilog\n", stdout_capture.written());
    try std.testing.expect(!log.verboseEnabled());
}

test "a console log with its options on writes verbose to stdout, debug to stderr and the output of tools to stdout" {
    var stdout_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr_capture.deinit();
    console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer console.setCapture(null, null);
    const log = ConsoleLog.initWith(.{
        .verbose = true,
        .debug = true,
        .tools = true,
    });
    log.verbose("verbose message");
    log.debug("debug message");
    log.tool("some-tool", .{
        .stdout = "out",
        .stderr = "err",
    });
    log.tool("quiet-tool", .{
        .stdout = "",
        .stderr = null,
    });
    try std.testing.expectEqualStrings("verbose message\n== some-tool stdout ==\nout\n== some-tool stderr ==\nerr\n", stdout_capture.written());
    try std.testing.expectEqualStrings("debug message\n", stderr_capture.written());
    try std.testing.expect(log.verboseEnabled());
}

test "each option of a console log turns on only its own lines" {
    var stdout_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr_capture.deinit();
    console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer console.setCapture(null, null);
    const debugOnly = ConsoleLog.initWith(.{
        .verbose = false,
        .debug = true,
        .tools = false,
    });
    const log = debugOnly;
    log.verbose("verbose message");
    log.debug("debug message");
    log.tool("some-tool", .{
        .stdout = "out",
        .stderr = null,
    });
    try std.testing.expectEqualStrings("", stdout_capture.written());
    try std.testing.expectEqualStrings("debug message\n", stderr_capture.written());
}

test "a console log writes a long tool output, event and error chain whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer console.setCapture(null, null);
    const log = ConsoleLog.initWith(.{
        .verbose = false,
        .debug = false,
        .tools = true,
    });
    const longText = try allocator.alloc(u8, 20000);
    @memset(longText, 'x');
    log.tool("ffprobe", .{
        .stdout = longText,
        .stderr = null,
    });
    log.event(longText);
    try std.testing.expectEqualStrings(try std.mem.concat(allocator, u8, &.{ "== ffprobe stdout ==\n", longText, "\n[EVENT] ", longText, "\n" }), stdout_capture.written());

    // An error whose message and cause together run past 16 KB.
    errors.recordError("Error", "{s}", .{longText[0..12000]});
    log.exception("Something failed", errors.throwErrorWithCause("{s}", .{longText[0..12000]}));
    try std.testing.expectEqualStrings(try std.mem.concat(allocator, u8, &.{ "Something failed\nError: ", longText[0..12000], "\nCaused by:\nError: ", longText[0..12000], "\n" }), stderr_capture.written());
}
