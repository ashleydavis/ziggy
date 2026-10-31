//
// Tests of MemoryLog, the log a test checks what was logged with.
//

const std = @import("std");

const MemoryLog = @import("log").memory_log.MemoryLog;

test "a memory log with no options records info and event as stdout, error, warn and exception as stderr and leaves out verbose, debug and tool lines" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    memory.log.info("info message");
    memory.log.verbose("verbose message");
    memory.log.@"error"("error message");
    memory.log.warn("warn message");
    memory.log.debug("debug message");
    memory.log.event("something happened");
    memory.log.tool("magick", .{
        .stdout = "tool output",
        .stderr = null,
    });
    try std.testing.expectEqualStrings("info message\n[EVENT] something happened\n", memory.stdout());
    try std.testing.expectEqualStrings("error message\nwarn message\n", memory.stderr());
    try std.testing.expect(!memory.log.verboseEnabled());
    try std.testing.expect(memory.log.logFilePath() == null);
}

test "a memory log with its options on records verbose, debug and the output of tools" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = true,
        .debug = true,
        .tools = true,
    });
    defer memory.deinit();
    memory.log.verbose("verbose message");
    memory.log.debug("debug message");
    memory.log.tool("magick", .{
        .stdout = "tool output",
        .stderr = "tool error",
    });
    try std.testing.expectEqualStrings("verbose message\n== magick stdout ==\ntool output\n== magick stderr ==\ntool error\n", memory.stdout());
    try std.testing.expectEqualStrings("debug message\n", memory.stderr());
    try std.testing.expect(memory.log.verboseEnabled());
}

test "a memory log records an exception with its error" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    memory.log.exception("Failed.", error.Boom);
    try std.testing.expectEqualStrings("Failed.\nError: Boom\n", memory.stderr());
    try std.testing.expectEqualStrings("", memory.stdout());
}
