//
// The record of the app's windows, which Quit reads. On Linux and macOS each window of the app is a process of its own, and each
// records itself as a file named by its process id in `<data dir>/windows`. A Quit in one sends every other recorded process of the
// same executable SIGTERM, which each window handles as its own quit. Each process writes and removes only its own file, and the
// next Quit removes a file left by a process that died. Windows, Android and iOS have no app-wide Quit and fail with
// NoAppWideQuit.
//

const std = @import("std");
const builtin = @import("builtin");

//
// The macOS function that gives a process's executable path. It is in libproc, which every macOS SDK has.
//
extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffer_size: u32) c_int;

//
// Whether this target runs each window of the app as a process of its own, so a Quit can end every one of them.
//
fn hasAppWideQuit() bool {
    return builtin.os.tag == .macos or (builtin.os.tag == .linux and !builtin.abi.isAndroid());
}

//
// This process's id.
//
pub fn own_process_id() !i32 {
    if (comptime hasAppWideQuit()) {
        if (comptime builtin.os.tag == .macos) {
            return std.c.getpid();
        }
        return std.os.linux.getpid();
    }
    else {
        return error.NoAppWideQuit;
    }
}

//
// Writes the path of the record of the process in the buffer and gives the slice used. Usage: record_path <buffer> <data dir> <pid>
//
fn record_path(buffer: []u8, data_dir: []const u8, pid: i32) ![]const u8 {
    return try std.fmt.bufPrint(buffer, "{s}/windows/{d}", .{ data_dir, pid });
}

//
// Creates `<data dir>/windows` when it is not there and writes this process's record there, which is an empty file named by its
// process id.
//
pub fn register(io: std.Io, data_dir: []const u8, pid: i32) !void {
    if (comptime hasAppWideQuit()) {
        std.debug.assert(pid > 0);
        var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const windows_dir = try std.fmt.bufPrint(&dir_buffer, "{s}/windows", .{data_dir});
        try std.Io.Dir.cwd().createDirPath(io, windows_dir);
        var record_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const record = try record_path(&record_buffer, data_dir, pid);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = record,
            .data = "",
        });
    }
    else {
        return error.NoAppWideQuit;
    }
}

//
// Removes this process's record. A record that is already gone is not an error, because a Quit may have removed it.
//
pub fn unregister(io: std.Io, data_dir: []const u8, pid: i32) !void {
    if (comptime hasAppWideQuit()) {
        std.debug.assert(pid > 0);
        var record_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const record = try record_path(&record_buffer, data_dir, pid);
        std.Io.Dir.cwd().deleteFile(io, record) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    else {
        return error.NoAppWideQuit;
    }
}

//
// The executable path of a running process, written into the buffer, or null when there is no such process. A zombie has no
// executable, so it counts as gone.
//
pub fn process_executable_path(io: std.Io, pid: i32, buffer: []u8) !?[]const u8 {
    if (comptime hasAppWideQuit()) {
        if (comptime builtin.os.tag == .macos) {
            const written = proc_pidpath(pid, buffer.ptr, @intCast(buffer.len));
            if (written <= 0) {
                return null;
            }
            return buffer[0..@intCast(written)];
        }
        // The path is written in a buffer of its own, because readLinkAbsolute writes the link's target into the buffer given.
        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/exe", .{pid});
        const written = std.Io.Dir.readLinkAbsolute(io, path, buffer) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return buffer[0..written];
    }
    else {
        return error.NoAppWideQuit;
    }
}

//
// The process calling end_others, and its executable path, as process_executable_path gives it, so the two paths compared cannot be
// swapped.
//
pub const OwnProcess = struct {
    // The process calling end_others, whose own record it leaves alone.
    pid: i32,
    // Its executable path, which a record must name for its process to be ended.
    executable: []const u8,
};

//
// Reads a record's name as a process id, or null when it is not a positive decimal number.
//
fn recorded_pid(name: []const u8) ?i32 {
    if (name.len == 0) {
        return null;
    }
    for (name) |character| {
        if (!std.ascii.isDigit(character)) {
            return null;
        }
    }
    const pid = std.fmt.parseInt(i32, name, 10) catch return null;
    if (pid <= 0) {
        return null;
    }
    return pid;
}

//
// Ends every other window of the app recorded in `<data dir>/windows`: a record whose process is gone, or whose executable is not
// own.executable, is removed; every other process is sent SIGTERM. Own.pid's own record is left alone. Returns how many processes
// were sent SIGTERM. A name that is not a positive decimal process id fails with InvalidWindowRecord once the other records are
// handled. A directory that is not there has no records.
//
pub fn end_others(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8, own: OwnProcess) !u32 {
    if (comptime hasAppWideQuit()) {
        const windows_dir_path = try std.fmt.allocPrint(allocator, "{s}/windows", .{data_dir});
        defer allocator.free(windows_dir_path);
        var dir = std.Io.Dir.cwd().openDir(io, windows_dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer dir.close(io);
        var sent: u32 = 0;
        var invalid_record = false;
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            const pid = recorded_pid(entry.name) orelse {
                invalid_record = true;
                continue;
            };
            if (pid == own.pid) {
                continue;
            }
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ windows_dir_path, entry.name });
            defer allocator.free(file_path);
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const executable = try process_executable_path(io, pid, &path_buffer);
            if (executable) |path| {
                if (std.mem.eql(u8, path, own.executable)) {
                    std.posix.kill(pid, .TERM) catch |err| switch (err) {
                        error.ProcessNotFound => {},
                        else => return err,
                    };
                    sent += 1;
                    continue;
                }
            }
            try std.Io.Dir.cwd().deleteFile(io, file_path);
        }
        if (invalid_record) {
            return error.InvalidWindowRecord;
        }
        return sent;
    }
    else {
        return error.NoAppWideQuit;
    }
}

//
// Records this process as a window of the app.
//
pub fn window_opened(io: std.Io, data_dir: []const u8) !void {
    if (comptime hasAppWideQuit()) {
        return try register(io, data_dir, try own_process_id());
    }
    else {
        return error.NoAppWideQuit;
    }
}

//
// Removes this process's record as a window of the app.
//
pub fn window_closed(io: std.Io, data_dir: []const u8) !void {
    if (comptime hasAppWideQuit()) {
        return try unregister(io, data_dir, try own_process_id());
    }
    else {
        return error.NoAppWideQuit;
    }
}

//
// Ends every other window of the app, comparing each recorded process's executable with this process's, both read the same way so a
// recorded id another program now has is not signalled.
//
pub fn end_other_windows(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) !u32 {
    if (comptime hasAppWideQuit()) {
        const pid = try own_process_id();
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const executable = (try process_executable_path(io, pid, &path_buffer)) orelse return error.OwnExecutableUnknown;
        return try end_others(io, allocator, data_dir, .{
            .pid = pid,
            .executable = executable,
        });
    }
    else {
        return error.NoAppWideQuit;
    }
}
