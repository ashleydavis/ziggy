//
// The log's system message: log, which `window.ziggy.log` sends so a line the frontend logs is written by the main thread's log.
//

const std = @import("std");
const ziggy_log = @import("log");
const worker_pool = @import("../worker-pool.zig");

//
// The data of log.
//
pub const LogRequest = struct {
    // The level: info, verbose, error, exception, warn, debug, tool or event.
    level: []const u8,
    // The line, or for the tool level the name of the tool.
    message: []const u8,
    // For the exception level, the text of the error, or null.
    @"error": ?[]const u8 = null,
    // For the tool level, what the tool wrote, or null.
    toolData: ?ToolData = null,
};

//
// What a tool wrote, in a log message of the tool level.
//
pub const ToolData = struct {
    // What the tool wrote to its standard output, or null.
    stdout: ?[]const u8 = null,
    // What the tool wrote to its standard error, or null.
    stderr: ?[]const u8 = null,
};

//
// The message response to log, an empty object.
//
pub const DoneResponse = struct {};

//
// Writes a line the frontend logged to the main thread's log, the one given, tagged with the source `Frontend`. A level that is not one
// of the eight fails with UnknownLogLevel, which is reported to the frontend as a core-error system event.
//
pub fn log(arena: std.mem.Allocator, main_log: ziggy_log.log.ILog, request: LogRequest) !DoneResponse {
    const level = std.meta.stringToEnum(ziggy_log.log.LogLevel, request.level) orelse {
        return error.UnknownLogLevel;
    };
    var tool_output: ?ziggy_log.log.IToolOutput = null;
    if (request.toolData) |data| {
        tool_output = .{
            .stdout = data.stdout,
            .stderr = data.stderr,
        };
    }
    worker_pool.writeTaggedLine(arena, main_log, "Frontend", .{
        .level = level,
        .message = request.message,
        .error_text = request.@"error",
        .tool_output = tool_output,
    });
    return .{};
}
