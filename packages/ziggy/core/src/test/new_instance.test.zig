//
// Checks starting another window of the app as a process of its own: the arguments it gets, the environment it gets, and the
// process group it stays in.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");

const new_instance = ziggy.new_instance;

// The process group of a process, which std has no binding for.
extern "c" fn getpgid(pid: std.c.pid_t) std.c.pid_t;

// Sets an environment variable of this process.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// Removes an environment variable of this process.
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

//
// Waits for a process and gives the code it exited with. Fails when it did not exit or another process was waited for.
//
fn waitForExit(pid: std.c.pid_t) !u8 {
    var status: c_int = 0;
    const waited = std.c.waitpid(pid, &status, 0);
    try std.testing.expectEqual(pid, waited);
    const wait_status: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(wait_status));
    return std.c.W.EXITSTATUS(wait_status);
}

//
// Makes the arguments of a new window and frees them, for the allocation failure test.
//
fn argumentsAndFree(allocator: std.mem.Allocator) !void {
    const arguments = try new_instance.instance_arguments(allocator, &.{ "a", "b" }, "127.0.0.1:4001");
    allocator.free(arguments);
}

//
// Reads this process's environment into a map and frees it, for the allocation failure test.
//
fn environMapAndFree(allocator: std.mem.Allocator) !void {
    var map = try new_instance.process_environ_map(allocator);
    map.deinit();
}

//
// Starts a short program and waits for it, for the allocation failure test.
//
fn startAndWait(allocator: std.mem.Allocator) !void {
    var map = try new_instance.process_environ_map(allocator);
    defer map.deinit();
    const id = try new_instance.start_instance(std.testing.io, allocator, "/bin/sh", &.{ "-c", "exit 0" }, &map);
    _ = try waitForExit(@intCast(id));
}

test "the app's arguments pass through in order, and --remote-control with its address follow them" {
    const without = try new_instance.instance_arguments(std.testing.allocator, &.{ "-geometry=640x480", "--open" }, null);
    defer std.testing.allocator.free(without);
    try std.testing.expectEqual(@as(usize, 2), without.len);
    try std.testing.expectEqualStrings("-geometry=640x480", without[0]);
    try std.testing.expectEqualStrings("--open", without[1]);

    const with = try new_instance.instance_arguments(std.testing.allocator, &.{ "-geometry=640x480", "--open" }, "127.0.0.1:4001");
    defer std.testing.allocator.free(with);
    try std.testing.expectEqual(@as(usize, 4), with.len);
    try std.testing.expectEqualStrings("-geometry=640x480", with[0]);
    try std.testing.expectEqualStrings("--open", with[1]);
    try std.testing.expectEqualStrings("--remote-control", with[2]);
    try std.testing.expectEqualStrings("127.0.0.1:4001", with[3]);
}

test "no app arguments under remote control give the option and its address alone" {
    const arguments = try new_instance.instance_arguments(std.testing.allocator, &.{}, "127.0.0.1:4001");
    defer std.testing.allocator.free(arguments);
    try std.testing.expectEqual(@as(usize, 2), arguments.len);
    try std.testing.expectEqualStrings("--remote-control", arguments[0]);
    try std.testing.expectEqualStrings("127.0.0.1:4001", arguments[1]);
}

test "an app argument of --remote-control fails with RemoteControlArgument" {
    try std.testing.expectError(error.RemoteControlArgument, new_instance.instance_arguments(std.testing.allocator, &.{ "--open", "--remote-control" }, "127.0.0.1:4001"));
}

test "running out of memory making the arguments fails cleanly" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, argumentsAndFree, .{});
}

test "the environment map holds PATH with the value the process has" {
    if (comptime (builtin.os.tag == .linux and !builtin.abi.isAndroid()) or builtin.os.tag == .macos) {
        var map = try new_instance.process_environ_map(std.testing.allocator);
        defer map.deinit();
        const process_path = std.c.getenv("PATH") orelse return error.TestUnexpectedResult;
        const map_path = map.get("PATH") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(std.mem.span(process_path), map_path);
        try std.testing.expect(std.ascii.eqlIgnoreCase(map_path, std.mem.span(process_path)));
    }
}

test "running out of memory reading the environment fails cleanly" {
    if (comptime (builtin.os.tag == .linux and !builtin.abi.isAndroid()) or builtin.os.tag == .macos) {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, environMapAndFree, .{});
    }
}

test "a started program exits with the code it was given" {
    if (comptime (builtin.os.tag == .linux and !builtin.abi.isAndroid()) or builtin.os.tag == .macos) {
        var map = try new_instance.process_environ_map(std.testing.allocator);
        defer map.deinit();
        const id = try new_instance.start_instance(std.testing.io, std.testing.allocator, "/bin/sh", &.{ "-c", "exit 7" }, &map);
        try std.testing.expect(id > 0);
        try std.testing.expectEqual(@as(u8, 7), try waitForExit(@intCast(id)));
    }
}

test "a started program gets the environment it is given" {
    if (comptime (builtin.os.tag == .linux and !builtin.abi.isAndroid()) or builtin.os.tag == .macos) {
        var given = std.process.Environ.Map.init(std.testing.allocator);
        defer given.deinit();
        try given.put("ZIGGY_NEW_INSTANCE_TEST", "given");
        const with = try new_instance.start_instance(std.testing.io, std.testing.allocator, "/bin/sh", &.{ "-c", "test \"$ZIGGY_NEW_INSTANCE_TEST\" = given" }, &given);
        try std.testing.expectEqual(@as(u8, 0), try waitForExit(@intCast(with)));

        var empty = std.process.Environ.Map.init(std.testing.allocator);
        defer empty.deinit();
        const without = try new_instance.start_instance(std.testing.io, std.testing.allocator, "/bin/sh", &.{ "-c", "test \"$ZIGGY_NEW_INSTANCE_TEST\" = given" }, &empty);
        try std.testing.expectEqual(@as(u8, 1), try waitForExit(@intCast(without)));
    }
}

test "running out of memory starting a program fails cleanly" {
    if (comptime (builtin.os.tag == .linux and !builtin.abi.isAndroid()) or builtin.os.tag == .macos) {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, startAndWait, .{});
    }
}

test "a started program stays in this process's group" {
    if (comptime (builtin.os.tag == .linux and !builtin.abi.isAndroid()) or builtin.os.tag == .macos) {
        var map = try new_instance.process_environ_map(std.testing.allocator);
        defer map.deinit();
        const id = try new_instance.start_instance(std.testing.io, std.testing.allocator, "/bin/sleep", &.{"30"}, &map);
        const pid: std.c.pid_t = @intCast(id);
        try std.testing.expectEqual(getpgid(0), getpgid(pid));
        _ = std.c.kill(pid, .KILL);
        var status: c_int = 0;
        try std.testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    }
}

test "a started program gets this process's environment" {
    if (comptime (builtin.os.tag == .linux and !builtin.abi.isAndroid()) or builtin.os.tag == .macos) {
        try std.testing.expectEqual(@as(c_int, 0), setenv("ZIGGY_NEW_INSTANCE_TEST", "given", 1));
        defer {
            _ = unsetenv("ZIGGY_NEW_INSTANCE_TEST");
        }
        // The map start_program reads the environment into lives on the arena, which the caller owns, as a native app's call does.
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const matching = try new_instance.start_program(std.testing.io, arena, "/bin/sh", &.{ "-c", "test \"$ZIGGY_NEW_INSTANCE_TEST\" = given" });
        try std.testing.expectEqual(@as(u8, 0), try waitForExit(@intCast(matching)));
        const seven = try new_instance.start_program(std.testing.io, arena, "/bin/sh", &.{ "-c", "exit 7" });
        try std.testing.expectEqual(@as(u8, 7), try waitForExit(@intCast(seven)));
    }
}

test "a new window is unavailable on Android and iOS" {
    if (comptime builtin.os.tag == .ios or builtin.abi.isAndroid()) {
        var map = std.process.Environ.Map.init(std.testing.allocator);
        defer map.deinit();
        try std.testing.expectError(error.NewWindowUnavailable, new_instance.process_environ_map(std.testing.allocator));
        try std.testing.expectError(error.NewWindowUnavailable, new_instance.start_instance(std.testing.io, std.testing.allocator, "/bin/sh", &.{}, &map));
        try std.testing.expectError(error.NewWindowUnavailable, new_instance.start_program(std.testing.io, std.testing.allocator, "/bin/sh", &.{}));
    }
}

test "on Windows the environment map holds PATH and a program starts" {
    if (comptime builtin.os.tag == .windows) {
        var map = try new_instance.process_environ_map(std.testing.allocator);
        defer map.deinit();
        var found = false;
        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "PATH")) {
                found = true;
            }
        }
        try std.testing.expect(found);
        const id = try new_instance.start_program(std.testing.io, std.testing.allocator, "C:\\Windows\\System32\\cmd.exe", &.{ "/c", "exit 0" });
        try std.testing.expect(id > 0);
    }
}
