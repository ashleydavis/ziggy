const std = @import("std");
const standard_streams = @import("standard-streams.zig");
const builtin = @import("builtin");

//
// A console that writes lines to the process streams.
// `console.log` and `console.debug` write a line to stdout, `console.error` and `console.warn`
// write a line to stderr. Output can be captured by tests with setCapture.
//
// The console needs no Io instance from the caller, so this uses the Io instance that
// std.debug uses (std.Options.debug_io), which is independent of the application's Io.
//

//
// Only the main thread writes stdout and stderr. A worker sets a forward, and its lines go to the main thread, which writes them.
//

//
// Which of the process's streams a line is for.
//
pub const Stream = enum {
    stdout,
    stderr,
};

//
// Where the calling thread's console lines go instead of the process's streams: a worker's go to the main thread.
//
pub const Forward = struct {
    // The forward's own pointer, passed back on every call.
    context: ?*anyopaque,
    // Takes one line, which is valid only during the call.
    function: *const fn (context: ?*anyopaque, stream: Stream, line: []const u8) void,
};

//
// When set, the calling thread's lines go here instead of to the process's streams.
//
threadlocal var forward: ?Forward = null;

//
// When set, lines the calling thread writes to stdout are written here instead (used by tests).
//
threadlocal var captured_stdout: ?*std.Io.Writer = null;

//
// When set, lines the calling thread writes to stderr are written here instead (used by tests).
//
threadlocal var captured_stderr: ?*std.Io.Writer = null;

//
// Redirects the calling thread's console output to the given writers (pass null to restore the real stdout/stderr).
//
pub fn setCapture(stdout_writer: ?*std.Io.Writer, stderr_writer: ?*std.Io.Writer) void {
    captured_stdout = stdout_writer;
    captured_stderr = stderr_writer;
}

//
// Sends the calling thread's console lines to the forward given (pass null to write them to the process's streams again).
//
pub fn setForward(lines_to: ?Forward) void {
    forward = lines_to;
}

//
// Writes a line to stdout, ignoring write errors (like console.log).
//
fn writeStdoutLine(message: []const u8) void {
    const io = std.Options.debug_io;
    if (forward) |lines_to| {
        lines_to.function(lines_to.context, .stdout, message);
        return;
    }
    if (captured_stdout) |capture_writer| {
        capture_writer.writeAll(message) catch {};
        capture_writer.writeByte('\n') catch {};
        return;
    }
    // In a test program stdout belongs to Zig's test runner, which talks to the build system over it, so a line there would break
    // that conversation. Each thread has a capture of its own, and a thread a test starts has none, so its line goes to stderr.
    if (builtin.is_test) {
        writeStderrLine(message);
        return;
    }
    var buffer: [1024]u8 = undefined;
    var file_writer = standard_streams.stdout().writerStreaming(io, &buffer);
    const stdout = &file_writer.interface;
    stdout.writeAll(message) catch {};
    stdout.writeByte('\n') catch {};
    stdout.flush() catch {};
}

//
// Writes a line to stderr, ignoring write errors (like console.error).
//
fn writeStderrLine(message: []const u8) void {
    if (forward) |lines_to| {
        lines_to.function(lines_to.context, .stderr, message);
        return;
    }
    var buffer: [1024]u8 = undefined;
    const locked_stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    if (captured_stderr) |capture_writer| {
        capture_writer.writeAll(message) catch {};
        capture_writer.writeByte('\n') catch {};
        return;
    }

    // std describes its stderr as synchronous even when the handle is not (see standard-streams.zig).
    locked_stderr.file_writer.file = standard_streams.withActualMode(locked_stderr.file_writer.file);
    const stderr = &locked_stderr.file_writer.interface;
    stderr.writeAll(message) catch {};
    stderr.writeByte('\n') catch {};
}

//
// Equivalent of `console.log(message)`: writes a line to stdout.
//
pub fn log(message: []const u8) void {
    writeStdoutLine(message);
}

//
// Equivalent of `console.error(message)`: writes a line to stderr.
//
pub fn @"error"(message: []const u8) void {
    writeStderrLine(message);
}

//
// Equivalent of `console.warn(message)`: writes a line to stderr.
//
pub fn warn(message: []const u8) void {
    writeStderrLine(message);
}

//
// Equivalent of `console.debug(message)`: writes a line to stdout.
//
pub fn debug(message: []const u8) void {
    writeStdoutLine(message);
}

//
// Equivalent of `console.error(<formatted message>)` for a message built from a format string.
// Messages longer than the internal buffer are truncated.
//
pub fn errorFormat(comptime format: []const u8, args: anytype) void {
    var buffer: [16 * 1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
    writeStderrLine(message);
}

//
// Equivalent of `console.log(<formatted message>)` for a message built from a format string.
// Messages longer than the internal buffer are truncated.
//
pub fn logFormat(comptime format: []const u8, args: anytype) void {
    var buffer: [16 * 1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
    writeStdoutLine(message);
}
