//
// Checks the record each window of the app keeps of itself and the Quit that ends every other window: which records are removed,
// which processes are sent SIGTERM, and the failures of both.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");

const app_windows = ziggy.app_windows;

//
// Whether this target runs each window of the app as a process of its own.
//
fn hasAppWideQuit() bool {
    return builtin.os.tag == .macos or (builtin.os.tag == .linux and !builtin.abi.isAndroid());
}

//
// A temporary data directory of the test's own, which the records go under.
//
const Fixture = struct {
    // The temporary directory of the test.
    tmp: std.testing.TmpDir,
    // The app's data directory inside it.
    data_dir: []const u8,
    // The allocator the data directory's path is allocated with.
    allocator: std.mem.Allocator,

    //
    // Makes the data directory's path. Nothing is created on disk until a record is written.
    //
    fn init(allocator: std.mem.Allocator) !Fixture {
        const tmp = std.testing.tmpDir(.{});
        const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/data", .{&tmp.sub_path});
        return .{
            .tmp = tmp,
            .data_dir = data_dir,
            .allocator = allocator,
        };
    }

    //
    // Frees the path and the temporary directory.
    //
    fn deinit(self: *Fixture) void {
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    //
    // The path of a record in the windows directory.
    //
    fn recordPath(self: *Fixture, pid: i32) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}/windows/{d}", .{ self.data_dir, pid });
    }
};

//
// Starts a program and gives its process id, leaving it for the test to wait for.
//
fn spawnProgram(argv: []const []const u8) !std.c.pid_t {
    const child = try std.process.spawn(std.testing.io, .{
        .argv = argv,
        .cwd = .inherit,
        .environ_map = null,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = null,
    });
    return child.id.?;
}

//
// Starts a program that runs until it is ended.
//
fn startSleep() !std.c.pid_t {
    return try spawnProgram(&.{ "/bin/sleep", "30" });
}

//
// Waits for a process, whatever ended it.
//
fn waitForExit(pid: std.c.pid_t) !void {
    var status: c_int = 0;
    try std.testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
}

//
// Waits for a process and gives the signal that ended it.
//
fn waitForSignal(pid: std.c.pid_t) !std.c.SIG {
    var status: c_int = 0;
    try std.testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    const wait_status: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFSIGNALED(wait_status));
    return std.c.W.TERMSIG(wait_status);
}

//
// Checks that a process is still running, without waiting for it.
//
fn expectRunning(pid: std.c.pid_t) !void {
    var status: c_int = 0;
    try std.testing.expectEqual(@as(std.c.pid_t, 0), std.c.waitpid(pid, &status, std.c.W.NOHANG));
}

//
// Ends a process the test started and waits for it.
//
fn endAndWait(pid: std.c.pid_t) !void {
    _ = std.c.kill(pid, .KILL);
    try waitForExit(pid);
}

//
// Ends the other windows of a directory with records written again for the allocation failure test.
//
fn endOthersAndFree(allocator: std.mem.Allocator, data_dir: []const u8, own_pid: i32, ended_pid: i32, executable: []const u8) !void {
    try app_windows.register(std.testing.io, data_dir, own_pid);
    try app_windows.register(std.testing.io, data_dir, ended_pid);
    _ = try app_windows.end_others(std.testing.io, allocator, data_dir, .{
        .pid = own_pid,
        .executable = executable,
    });
}

test "own_process_id is the id of the process running the test" {
    if (comptime hasAppWideQuit()) {
        const pid = try app_windows.own_process_id();
        try std.testing.expect(pid > 0);
        const result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{ "/bin/sh", "-c", "echo $PPID" },
            .cwd = .inherit,
            .environ_map = null,
        });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expectEqual(pid, try std.fmt.parseInt(i32, std.mem.trim(u8, result.stdout, " \r\n"), 10));
    }
}

test "register writes the process's own record and unregister removes it" {
    if (comptime hasAppWideQuit()) {
        var fixture = try Fixture.init(std.testing.allocator);
        defer fixture.deinit();
        const pid = try app_windows.own_process_id();
        const record = try fixture.recordPath(pid);
        defer fixture.allocator.free(record);
        try app_windows.register(std.testing.io, fixture.data_dir, pid);
        try std.Io.Dir.cwd().access(std.testing.io, record, .{});
        try app_windows.unregister(std.testing.io, fixture.data_dir, pid);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, record, .{}));
        try app_windows.unregister(std.testing.io, fixture.data_dir, pid);
    }
}

test "process_executable_path gives a running process's executable and null for a process that has gone" {
    if (comptime hasAppWideQuit()) {
        const running = try startSleep();
        defer endAndWait(running) catch {};
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = (try app_windows.process_executable_path(std.testing.io, running, &buffer)).?;
        const expected = try std.Io.Dir.realPathFileAbsoluteAlloc(std.testing.io, "/bin/sleep", std.testing.allocator);
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, path);

        const gone = try spawnProgram(&.{ "/bin/sh", "-c", "exit 0" });
        try waitForExit(gone);
        var gone_buffer: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expect((try app_windows.process_executable_path(std.testing.io, gone, &gone_buffer)) == null);
    }
}

test "end_others sends SIGTERM to a registered window of the same executable" {
    if (comptime hasAppWideQuit()) {
        var fixture = try Fixture.init(std.testing.allocator);
        defer fixture.deinit();
        const own_pid = try app_windows.own_process_id();
        const child = try startSleep();
        defer endAndWait(child) catch {};
        const executable = try std.Io.Dir.realPathFileAbsoluteAlloc(std.testing.io, "/bin/sleep", std.testing.allocator);
        defer std.testing.allocator.free(executable);
        try app_windows.register(std.testing.io, fixture.data_dir, child);
        const sent = try app_windows.end_others(std.testing.io, std.testing.allocator, fixture.data_dir, .{
            .pid = own_pid,
            .executable = executable,
        });
        try std.testing.expectEqual(@as(u32, 1), sent);
        try std.testing.expectEqual(std.c.SIG.TERM, try waitForSignal(child));
    }
}

test "end_others removes the record of a window of another executable and leaves it running" {
    if (comptime hasAppWideQuit()) {
        var fixture = try Fixture.init(std.testing.allocator);
        defer fixture.deinit();
        const own_pid = try app_windows.own_process_id();
        const child = try startSleep();
        defer endAndWait(child) catch {};
        const other = try std.Io.Dir.realPathFileAbsoluteAlloc(std.testing.io, "/bin/sh", std.testing.allocator);
        defer std.testing.allocator.free(other);
        try app_windows.register(std.testing.io, fixture.data_dir, child);
        const record = try fixture.recordPath(child);
        defer fixture.allocator.free(record);
        const sent = try app_windows.end_others(std.testing.io, std.testing.allocator, fixture.data_dir, .{
            .pid = own_pid,
            .executable = other,
        });
        try std.testing.expectEqual(@as(u32, 0), sent);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, record, .{}));
        try expectRunning(child);
    }
}

test "end_others removes the record of a process that has ended" {
    if (comptime hasAppWideQuit()) {
        var fixture = try Fixture.init(std.testing.allocator);
        defer fixture.deinit();
        const own_pid = try app_windows.own_process_id();
        const gone = try spawnProgram(&.{ "/bin/sh", "-c", "exit 0" });
        try waitForExit(gone);
        try app_windows.register(std.testing.io, fixture.data_dir, gone);
        const record = try fixture.recordPath(gone);
        defer fixture.allocator.free(record);
        const sent = try app_windows.end_others(std.testing.io, std.testing.allocator, fixture.data_dir, .{
            .pid = own_pid,
            .executable = "another executable",
        });
        try std.testing.expectEqual(@as(u32, 0), sent);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, record, .{}));
    }
}

test "end_others skips the record of its own process and keeps it" {
    if (comptime hasAppWideQuit()) {
        var fixture = try Fixture.init(std.testing.allocator);
        defer fixture.deinit();
        const own_pid = try app_windows.own_process_id();
        try app_windows.register(std.testing.io, fixture.data_dir, own_pid);
        const record = try fixture.recordPath(own_pid);
        defer fixture.allocator.free(record);
        const sent = try app_windows.end_others(std.testing.io, std.testing.allocator, fixture.data_dir, .{
            .pid = own_pid,
            .executable = "another executable",
        });
        try std.testing.expectEqual(@as(u32, 0), sent);
        try std.Io.Dir.cwd().access(std.testing.io, record, .{});
    }
}

test "end_others handles the other records and then fails on a name that is not a pid" {
    if (comptime hasAppWideQuit()) {
        var fixture = try Fixture.init(std.testing.allocator);
        defer fixture.deinit();
        const own_pid = try app_windows.own_process_id();
        const child = try startSleep();
        defer endAndWait(child) catch {};
        const executable = try std.Io.Dir.realPathFileAbsoluteAlloc(std.testing.io, "/bin/sleep", std.testing.allocator);
        defer std.testing.allocator.free(executable);
        try app_windows.register(std.testing.io, fixture.data_dir, child);
        const not_a_pid = try std.fmt.allocPrint(fixture.allocator, "{s}/windows/notapid", .{fixture.data_dir});
        defer fixture.allocator.free(not_a_pid);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = not_a_pid,
            .data = "",
        });
        try std.testing.expectError(error.InvalidWindowRecord, app_windows.end_others(std.testing.io, std.testing.allocator, fixture.data_dir, .{
            .pid = own_pid,
            .executable = executable,
        }));
        try std.testing.expectEqual(std.c.SIG.TERM, try waitForSignal(child));
    }
}

test "end_others succeeds when there is no windows directory" {
    if (comptime hasAppWideQuit()) {
        var fixture = try Fixture.init(std.testing.allocator);
        defer fixture.deinit();
        const own_pid = try app_windows.own_process_id();
        const sent = try app_windows.end_others(std.testing.io, std.testing.allocator, fixture.data_dir, .{
            .pid = own_pid,
            .executable = "another executable",
        });
        try std.testing.expectEqual(@as(u32, 0), sent);
    }
}

test "running out of memory ending other windows fails cleanly" {
    if (comptime hasAppWideQuit()) {
        var fixture = try Fixture.init(std.testing.allocator);
        defer fixture.deinit();
        const own_pid = try app_windows.own_process_id();
        const gone = try spawnProgram(&.{ "/bin/sh", "-c", "exit 0" });
        try waitForExit(gone);
        try std.testing.checkAllAllocationFailures(std.testing.allocator, endOthersAndFree, .{ fixture.data_dir, own_pid, gone, "another executable" });
    }
}

test "window_opened records the process and window_closed removes the record" {
    if (comptime hasAppWideQuit()) {
        var fixture = try Fixture.init(std.testing.allocator);
        defer fixture.deinit();
        const own_pid = try app_windows.own_process_id();
        const record = try fixture.recordPath(own_pid);
        defer fixture.allocator.free(record);
        try app_windows.window_opened(std.testing.io, fixture.data_dir);
        try std.Io.Dir.cwd().access(std.testing.io, record, .{});
        try app_windows.window_closed(std.testing.io, fixture.data_dir);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, record, .{}));
    }
}

test "end_other_windows removes a window of another executable and keeps this window's record" {
    if (comptime hasAppWideQuit()) {
        var fixture = try Fixture.init(std.testing.allocator);
        defer fixture.deinit();
        const own_pid = try app_windows.own_process_id();
        const child = try startSleep();
        defer endAndWait(child) catch {};
        try app_windows.window_opened(std.testing.io, fixture.data_dir);
        try app_windows.register(std.testing.io, fixture.data_dir, child);
        const own_record = try fixture.recordPath(own_pid);
        defer fixture.allocator.free(own_record);
        const child_record = try fixture.recordPath(child);
        defer fixture.allocator.free(child_record);
        const sent = try app_windows.end_other_windows(std.testing.io, std.testing.allocator, fixture.data_dir);
        try std.testing.expectEqual(@as(u32, 0), sent);
        try std.Io.Dir.cwd().access(std.testing.io, own_record, .{});
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, child_record, .{}));
        try expectRunning(child);
    }
}

test "an app-wide Quit is unavailable on the other targets" {
    if (comptime !hasAppWideQuit()) {
        try std.testing.expectError(error.NoAppWideQuit, app_windows.register(std.testing.io, "data", 1));
        try std.testing.expectError(error.NoAppWideQuit, app_windows.window_opened(std.testing.io, "data"));
        try std.testing.expectError(error.NoAppWideQuit, app_windows.window_closed(std.testing.io, "data"));
        try std.testing.expectError(error.NoAppWideQuit, app_windows.end_other_windows(std.testing.io, std.testing.allocator, "data"));
    }
}
