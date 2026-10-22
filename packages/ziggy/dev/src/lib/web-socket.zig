//
// Reads the messages a browser sends on a WebSocket (RFC 6455). A browser splits a large message into frames, a first frame and
// continuation frames, which the standard library's reader refuses, so the frames are joined here. Control frames may arrive
// between the frames of a message: a ping is handed to the caller's handler to reply to and the read carries on, a pong is skipped,
// and a close ends the read.
//

const std = @import("std");

const Opcode = std.http.Server.WebSocket.Opcode;

//
// What a read returns.
//
pub const Message = union(enum) {
    // A whole text or binary message, joined from its frames. The caller owns it.
    data: []u8,
    // The browser closed the connection.
    close,
};

//
// Replies to a ping with a pong carrying its payload. Called during a read, with the payload, which is valid only for the call.
//
pub const PingHandler = struct {
    // What the handler is given back.
    context: *anyopaque,
    // Replies to the ping.
    answer: *const fn (context: *anyopaque, payload: []const u8) anyerror!void,
};

//
// Reads the next message, joining a split one. A message whose frames add up to more than the limit is error.MessageTooLarge.
//
pub fn readMessage(reader: *std.Io.Reader, allocator: std.mem.Allocator, limit: usize, ping_handler: PingHandler) !Message {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    var in_message = false;
    while (true) {
        const header = try reader.takeArray(2);
        const fin = header[0] & 0x80 != 0;
        const opcode: Opcode = @enumFromInt(@as(u4, @truncate(header[0])));
        const masked = header[1] & 0x80 != 0;
        if (!masked) {
            // A browser masks every frame it sends, and the protocol requires refusing one that is not.
            return error.UnmaskedFrame;
        }
        const length: u64 = switch (header[1] & 0x7f) {
            126 => try reader.takeInt(u16, .big),
            127 => try reader.takeInt(u64, .big),
            else => |short| short,
        };
        const mask = (try reader.takeArray(4)).*;
        switch (opcode) {
            .ping, .pong, .connection_close => {
                if (length > 125 or !fin) {
                    return error.BadControlFrame;
                }
                var control_payload: [125]u8 = undefined;
                const payload = control_payload[0..@intCast(length)];
                try reader.readSliceAll(payload);
                unmask(payload, mask);
                switch (opcode) {
                    .ping => try ping_handler.answer(ping_handler.context, payload),
                    .connection_close => {
                        joined.deinit(allocator);
                        return .close;
                    },
                    else => {},
                }
                continue;
            },
            .text, .binary => {
                if (in_message) {
                    return error.UnexpectedNewMessage;
                }
                in_message = true;
            },
            .continuation => {
                if (!in_message) {
                    return error.UnexpectedContinuation;
                }
            },
            _ => return error.UnknownOpcode,
        }
        if (joined.items.len + length > limit) {
            return error.MessageTooLarge;
        }
        const payload = try joined.addManyAsSlice(allocator, @intCast(length));
        try reader.readSliceAll(payload);
        unmask(payload, mask);
        if (fin) {
            return .{
                .data = try joined.toOwnedSlice(allocator),
            };
        }
    }
}

//
// Undoes the mask a browser applies to a frame's payload. Each frame's mask starts again at the frame's first byte.
//
fn unmask(payload: []u8, mask: [4]u8) void {
    for (payload, 0..) |*byte, index| {
        byte.* ^= mask[index % 4];
    }
}
