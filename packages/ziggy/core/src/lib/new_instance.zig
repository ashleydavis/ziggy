//
// The command line of a new window of the app and starting it as a process of its own. The new process runs the app again, so it
// has its own window, backend and task queue, and stays in this process's group, which a smoke test that ends the group ends
// every window of. Android and iOS have one window, so every function that starts a process fails there with NewWindowUnavailable.
//

const std = @import("std");
const builtin = @import("builtin");

//
// The Windows API functions this file calls that std.os.windows does not declare.
//
const kernel32 = struct {
    // Gets the id of the process behind a handle.
    extern "kernel32" fn GetProcessId(process: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.DWORD;
};

//
// The arguments of a new window: the app's own arguments followed by --remote-control and the address when the app runs under a
// remote control server, so the new window connects to the same server. The strings are not copied, and the caller frees the list
// with the allocator. Fails with RemoteControlArgument when an app argument is --remote-control, because the window would then get
// the option twice and refuse to start.
//
pub fn instance_arguments(allocator: std.mem.Allocator, app_arguments: []const []const u8, remote_control: ?[]const u8) ![]const []const u8 {
    const extra: usize = if (remote_control != null) 2 else 0;
    var arguments: std.ArrayList([]const u8) = try .initCapacity(allocator, app_arguments.len + extra);
    errdefer arguments.deinit(allocator);
    for (app_arguments) |argument| {
        if (std.mem.eql(u8, argument, "--remote-control")) {
            return error.RemoteControlArgument;
        }
        arguments.appendAssumeCapacity(argument);
    }
    if (remote_control) |address| {
        arguments.appendAssumeCapacity("--remote-control");
        arguments.appendAssumeCapacity(address);
    }
    std.debug.assert(arguments.items.len == app_arguments.len + extra);
    return try arguments.toOwnedSlice(allocator);
}

//
// This process's whole environment, as a map allocated with the arena. A single threaded Io of this process's own has an empty
// environment on Linux and macOS, so a spawn given no environment would start the window with no DISPLAY, HOME, data directory
// overrides or anything else. Android and iOS have no new window and fail with NewWindowUnavailable.
//
pub fn process_environ_map(arena: std.mem.Allocator) !std.process.Environ.Map {
    if (comptime builtin.os.tag == .ios or builtin.abi.isAndroid()) {
        return error.NewWindowUnavailable;
    }
    if (comptime builtin.os.tag == .windows) {
        return try (std.process.Environ{ .block = .global }).createMap(arena);
    }
    return try (std.process.Environ{ .block = .{
        .slice = std.mem.span(std.c.environ),
    } }).createMap(arena);
}

//
// Starts the executable with the arguments after it and the environment given, and returns the new process's id as soon as it has
// started. The process inherits this process's standard streams and working directory and stays in its process group, which the
// caller leaves as it is (.pgid null). On Linux and macOS the caller reaps the process when it ends, or it stays a zombie; on
// Windows the handles are closed here. Android and iOS fail with NewWindowUnavailable.
//
pub fn start_instance(io: std.Io, allocator: std.mem.Allocator, executable: []const u8, arguments: []const []const u8, environ_map: *const std.process.Environ.Map) !u64 {
    if (comptime builtin.os.tag == .ios or builtin.abi.isAndroid()) {
        return error.NewWindowUnavailable;
    }
    const argv = try allocator.alloc([]const u8, arguments.len + 1);
    defer allocator.free(argv);
    argv[0] = executable;
    @memcpy(argv[1..], arguments);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .inherit,
        .environ_map = environ_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = null,
    });
    if (comptime builtin.os.tag == .windows) {
        const id = kernel32.GetProcessId(child.id.?);
        std.os.windows.CloseHandle(child.id.?);
        child.id = null;
        std.os.windows.CloseHandle(child.thread_handle);
        std.debug.assert(id > 0);
        return id;
    }
    else {
        const id = child.id.?;
        std.debug.assert(id > 0);
        return @intCast(id);
    }
}

//
// Starts the executable with the arguments after it and this process's whole environment, and returns the new process's id.
// Android and iOS fail with NewWindowUnavailable, from process_environ_map and start_instance.
//
pub fn start_program(io: std.Io, arena: std.mem.Allocator, executable: []const u8, arguments: []const []const u8) !u64 {
    var environ_map = try process_environ_map(arena);
    return try start_instance(io, arena, executable, arguments, &environ_map);
}
