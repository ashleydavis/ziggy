//
// How a thread of the core reaches the native app: it posts a copy of JSON text to the native app's queue and wakes the native app's
// UI thread, which takes it (see native-side.zig). No thread of the core calls into the native app or touches its state. A thread that
// needs a result gives the queue the result comes back on, its own, and waits there.
//

const std = @import("std");
const types = @import("types.zig");
const message_queue = @import("message-queue.zig");
const native_message = @import("native-message.zig");

const MessageQueue = message_queue.MessageQueue;

//
// Where a call's result goes: the queue of the thread that made the call, and the number its result comes back under.
//
pub const Reply = struct {
    // The queue of the thread waiting for the result.
    queue: *MessageQueue,
    // The number the result comes back under, as the request id of a `native-app-response`.
    call_id: u64,
};

//
// The native app's queue and how to wake its UI thread. It is a small value each thread holds a copy of. The native app's wake_data is
// handed to wake unread.
//
pub const NativeApp = struct {
    // The native app's queue.
    queue: *MessageQueue,
    // Wakes the native app's UI thread.
    wake: types.WakeFn,
    // What the native app gave to hand to wake.
    wake_data: ?*anyopaque,

    //
    // Sends a JSON message to the frontend, with the Io of the calling thread.
    //
    pub fn deliver(self: NativeApp, io: std.Io, message: []const u8) !void {
        try self.queue.post(io, @intCast(@intFromEnum(native_message.Kind.deliver)), message);
        self.wake(self.wake_data);
    }

    //
    // Has the native app do something, with the Io and the allocator of the calling thread. A call with a result is given where
    // the result goes.
    //
    pub fn call(self: NativeApp, io: std.Io, allocator: std.mem.Allocator, request: native_message.Call, reply: ?Reply) !void {
        const text = try native_message.encode(allocator, request, if (reply) |target| target.call_id else null);
        defer allocator.free(text);
        try self.queue.postReplyTo(io, @intCast(@intFromEnum(native_message.Kind.call)), text, if (reply) |target| target.queue else null);
        self.wake(self.wake_data);
    }
};
