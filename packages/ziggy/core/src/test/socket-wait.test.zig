const std = @import("std");
const ziggy = @import("ziggy");

const socket_wait = ziggy.socket_wait;

test "a listening socket is readable once a connection waits to be accepted, and not before" {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    try std.testing.expect(!try socket_wait.waitReadable(listener.socket.handle, 20));
    const client = try (try std.Io.net.IpAddress.parseIp4("127.0.0.1", listener.socket.address.getPort())).connect(io, .{ .mode = .stream });
    defer client.close(io);
    try std.testing.expect(try socket_wait.waitReadable(listener.socket.handle, 2000));
    const accepted = try listener.accept(io);
    accepted.close(io);
}

test "a connected socket is readable once bytes arrive, and waitReadableAny names the socket that has them" {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    const first = try (try std.Io.net.IpAddress.parseIp4("127.0.0.1", port)).connect(io, .{ .mode = .stream });
    defer first.close(io);
    const first_server = try listener.accept(io);
    defer first_server.close(io);
    const second = try (try std.Io.net.IpAddress.parseIp4("127.0.0.1", port)).connect(io, .{ .mode = .stream });
    defer second.close(io);
    const second_server = try listener.accept(io);
    defer second_server.close(io);
    const handles = [_]std.Io.net.Socket.Handle{ first_server.socket.handle, second_server.socket.handle };
    try std.testing.expect(try socket_wait.waitReadableAny(&handles, 20) == null);
    var buffer: [8]u8 = undefined;
    var writer = second.writer(io, &buffer);
    try writer.interface.writeAll("hi");
    try writer.interface.flush();
    try std.testing.expectEqual(@as(?usize, 1), try socket_wait.waitReadableAny(&handles, 2000));
    try std.testing.expect(try socket_wait.waitReadable(second_server.socket.handle, 2000));
    try std.testing.expect(!try socket_wait.waitReadable(first_server.socket.handle, 20));
}
