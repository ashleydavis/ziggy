//
// Waits, for no longer than a timeout, until a socket has something to read: a connection to accept on a listening socket, or bytes
// (or the end of the stream) on a connected one. A thread that serves a socket waits with it, so it gets back control every time the
// timeout passes and reads its messages then, instead of blocking in accept or read where nothing can reach it.
//

const std = @import("std");
const builtin = @import("builtin");

//
// The Windows API WSAPoll waits with, which std does not declare.
//
const ws2_32 = struct {
    // One socket WSAPoll waits on, and what it waits for and found.
    const WSAPOLLFD = extern struct {
        // The socket.
        fd: std.Io.net.Socket.Handle,
        // What to wait for.
        events: i16,
        // What was found.
        revents: i16,
    };

    // Normal data can be read, or a connection accepted.
    const POLLRDNORM: i16 = 0x0100;

    // Waits until one of the sockets is ready or the timeout, in milliseconds, passes. Returns the number of sockets ready, 0 on
    // a timeout and SOCKET_ERROR on failure.
    extern "ws2_32" fn WSAPoll(fdArray: [*]WSAPOLLFD, fds: u32, timeout: i32) callconv(.winapi) i32;
};

//
// Waits until the socket has something to read or the milliseconds given pass. Returns true when it has, and false when the time
// passed first.
//
pub fn waitReadable(handle: std.Io.net.Socket.Handle, timeout_ms: i32) !bool {
    return (try waitReadableAny(&.{handle}, timeout_ms)) != null;
}

//
// The most sockets waitReadableAny waits on at once.
//
pub const max_sockets = 4;

//
// Waits until one of the sockets has something to read or the milliseconds given pass. Returns the index of the first socket that
// has, or null when the time passed first.
//
pub fn waitReadableAny(handles: []const std.Io.net.Socket.Handle, timeout_ms: i32) !?usize {
    std.debug.assert(handles.len <= max_sockets);
    if (builtin.os.tag == .windows) {
        var fds: [max_sockets]ws2_32.WSAPOLLFD = undefined;
        for (handles, 0..) |handle, index| {
            fds[index] = .{
                .fd = handle,
                .events = ws2_32.POLLRDNORM,
                .revents = 0,
            };
        }
        const ready = ws2_32.WSAPoll(&fds, @intCast(handles.len), timeout_ms);
        if (ready < 0) {
            return error.SocketWaitFailed;
        }
        for (fds[0..handles.len], 0..) |fd, index| {
            if (fd.revents != 0) {
                return index;
            }
        }
        return null;
    }
    var fds: [max_sockets]std.posix.pollfd = undefined;
    for (handles, 0..) |handle, index| {
        fds[index] = .{
            .fd = handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
    }
    _ = try std.posix.poll(fds[0..handles.len], timeout_ms);
    for (fds[0..handles.len], 0..) |fd, index| {
        if (fd.revents != 0) {
            return index;
        }
    }
    return null;
}
