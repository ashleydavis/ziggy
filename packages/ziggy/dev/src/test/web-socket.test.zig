const std = @import("std");
const web_socket = @import("../lib/web-socket.zig");

const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };

//
// Appends one masked frame, as a browser sends it, to the bytes given.
//
fn appendFrame(bytes: *std.ArrayList(u8), fin: bool, opcode: u4, payload: []const u8) !void {
    const allocator = std.testing.allocator;
    try bytes.append(allocator, (if (fin) @as(u8, 0x80) else 0) | opcode);
    if (payload.len < 126) {
        try bytes.append(allocator, 0x80 | @as(u8, @intCast(payload.len)));
    }
    else if (payload.len <= 0xffff) {
        try bytes.append(allocator, 0x80 | 126);
        try bytes.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(payload.len))));
    }
    else {
        try bytes.append(allocator, 0x80 | 127);
        try bytes.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u64, payload.len)));
    }
    try bytes.appendSlice(allocator, &mask);
    for (payload, 0..) |byte, index| {
        try bytes.append(allocator, byte ^ mask[index % 4]);
    }
}

//
// Records the pings a read hands over.
//
const PingRecorder = struct {
    pings: std.ArrayList(u8) = .empty,

    fn answer(context: *anyopaque, payload: []const u8) anyerror!void {
        const self: *PingRecorder = @ptrCast(@alignCast(context));
        try self.pings.appendSlice(std.testing.allocator, payload);
        try self.pings.append(std.testing.allocator, '|');
    }

    fn handler(self: *PingRecorder) web_socket.PingHandler {
        return .{
            .context = self,
            .answer = answer,
        };
    }
};

test "a message in one frame is read and unmasked" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendFrame(&bytes, true, 1, "{\"channel\":\"ping\"}");
    var reader: std.Io.Reader = .fixed(bytes.items);
    var recorder = PingRecorder{};
    const message = try web_socket.readMessage(&reader, std.testing.allocator, 1024, recorder.handler());
    defer std.testing.allocator.free(message.data);
    try std.testing.expectEqualStrings("{\"channel\":\"ping\"}", message.data);
}

test "a message split into frames is joined, and a ping between them is answered without losing it" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendFrame(&bytes, false, 1, "first ");
    try appendFrame(&bytes, true, 9, "are you there");
    try appendFrame(&bytes, false, 0, "second ");
    try appendFrame(&bytes, true, 0, "third");
    var reader: std.Io.Reader = .fixed(bytes.items);
    var recorder = PingRecorder{};
    defer recorder.pings.deinit(std.testing.allocator);
    const message = try web_socket.readMessage(&reader, std.testing.allocator, 1024, recorder.handler());
    defer std.testing.allocator.free(message.data);
    try std.testing.expectEqualStrings("first second third", message.data);
    try std.testing.expectEqualStrings("are you there|", recorder.pings.items);
}

test "lengths written in two bytes and in eight bytes are read" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    const medium = try std.testing.allocator.alloc(u8, 300);
    defer std.testing.allocator.free(medium);
    @memset(medium, 'm');
    const large = try std.testing.allocator.alloc(u8, 70000);
    defer std.testing.allocator.free(large);
    @memset(large, 'l');
    try appendFrame(&bytes, true, 1, medium);
    try appendFrame(&bytes, true, 2, large);
    var reader: std.Io.Reader = .fixed(bytes.items);
    var recorder = PingRecorder{};
    const first = try web_socket.readMessage(&reader, std.testing.allocator, 100000, recorder.handler());
    defer std.testing.allocator.free(first.data);
    try std.testing.expectEqualSlices(u8, medium, first.data);
    const second = try web_socket.readMessage(&reader, std.testing.allocator, 100000, recorder.handler());
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, large, second.data);
}

test "a close frame ends the read, and a pong is skipped" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendFrame(&bytes, true, 10, "");
    try appendFrame(&bytes, true, 8, "");
    var reader: std.Io.Reader = .fixed(bytes.items);
    var recorder = PingRecorder{};
    const message = try web_socket.readMessage(&reader, std.testing.allocator, 1024, recorder.handler());
    try std.testing.expect(message == .close);
}

test "a message larger than the limit, an unmasked frame and a stray continuation are refused" {
    var recorder = PingRecorder{};
    {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(std.testing.allocator);
        try appendFrame(&bytes, false, 1, "12345");
        try appendFrame(&bytes, true, 0, "67890");
        var reader: std.Io.Reader = .fixed(bytes.items);
        try std.testing.expectError(error.MessageTooLarge, web_socket.readMessage(&reader, std.testing.allocator, 8, recorder.handler()));
    }
    {
        var reader: std.Io.Reader = .fixed(&.{ 0x81, 0x01, 'x' });
        try std.testing.expectError(error.UnmaskedFrame, web_socket.readMessage(&reader, std.testing.allocator, 8, recorder.handler()));
    }
    {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(std.testing.allocator);
        try appendFrame(&bytes, true, 0, "x");
        var reader: std.Io.Reader = .fixed(bytes.items);
        try std.testing.expectError(error.UnexpectedContinuation, web_socket.readMessage(&reader, std.testing.allocator, 8, recorder.handler()));
    }
}
