//
// A log that writes nothing, for a test whose code logs but whose test does not check what it logged. A test program must write
// nothing to stderr when it passes, because Zig 0.16.0 prints a misleading "failed command" line after any
// (https://codeberg.org/ziglang/zig/issues/35202), and the test output stays free of the lines of code under test.
//

const std = @import("std");
const log = @import("log.zig");

//
// The log that writes nothing.
//
pub const MuteLog = struct {
    //
    // Makes a log that writes nothing.
    //
    pub fn init() log.ILog {
        return .{
            // A mute log has no state, so its functions never read the pointer.
            .ptr = @constCast(&mute),
            .vtable = &muteLogVtable,
        };
    }

    //
    // The mute log every init gives out, which has no state.
    //
    const mute: MuteLog = .{};
};

//
// The ILog functions of MuteLog.
//
const muteLogVtable: log.ILog.VTable = .{
    .info = muteMessage,
    .verbose = muteMessage,
    .@"error" = muteMessage,
    .exception = muteException,
    .warn = muteMessage,
    .debug = muteMessage,
    .tool = muteTool,
    .event = muteMessage,
    .verboseEnabled = muteVerboseEnabled,
    .getLogDetails = muteLogDetails,
    .logFilePath = muteLogFilePath,
};

//
// Does nothing with a message.
//
fn muteMessage(ptr: *anyopaque, message: []const u8) void {
    _ = ptr;
    _ = message;
}

//
// Does nothing with an exception.
//
fn muteException(_: *anyopaque, _: []const u8, _: anyerror) void {}

//
// Does nothing with tool output.
//
fn muteTool(ptr: *anyopaque, toolName: []const u8, data: log.IToolOutput) void {
    _ = ptr;
    _ = toolName;
    _ = data;
}

//
// Verbose logging is off.
//
fn muteVerboseEnabled(ptr: *anyopaque) bool {
    _ = ptr;
    return false;
}

//
// Returns the placeholder log details.
//
fn muteLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!log.ILogDetails {
    _ = ptr;
    _ = allocator;
    _ = io;
    return log.noLogDetails;
}

//
// This log writes no file.
//
fn muteLogFilePath(ptr: *anyopaque) ?[]const u8 {
    _ = ptr;
    return null;
}
