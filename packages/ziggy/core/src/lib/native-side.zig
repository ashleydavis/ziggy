//
// The native app's side of its queue: what its UI thread takes the core's messages with and gives the results of calls with (see
// native-message.zig). Only the native app's UI thread uses it, so it keeps the calls waiting for their results to itself, each under a
// number it gives the native app, and posts each result to the queue of the thread that made the call.
//

const std = @import("std");
const message_queue = @import("message-queue.zig");
const native_message = @import("native-message.zig");
const native_app = @import("native-app.zig");

const MessageQueue = message_queue.MessageQueue;

//
// A message the native app took.
//
pub const Taken = struct {
    // Whether it is a message for the frontend or a call, or another kind, which the core never sends.
    kind: native_message.Kind,
    // Its JSON text, valid until the next take.
    text: []const u8,
    // The number to give the call's result with, or 0 for a message that has no result.
    reply: u64,
    // For a message of a kind the core never sends (one a fake native app's test sends it), where its reply goes, or null.
    reply_to: ?*MessageQueue,
};

//
// Where the messages for the frontend go that arrive while the core stops, for a native app that keeps them (a fake one does).
//
pub const FrontendSink = struct {
    // The sink's own pointer, passed back on every call.
    context: *anyopaque,
    // Takes one message, on the native app's UI thread, with its allocator. The text is valid only during the call.
    deliver: *const fn (context: *anyopaque, allocator: std.mem.Allocator, text: []const u8) void,
};

//
// The native app's side of its queue. It keeps no allocator: each function is given the UI thread's own.
//
pub const NativeSide = struct {
    // The native app's queue, which the core's threads post to. Its owner keeps it where it is while the core runs.
    queue: *MessageQueue,
    // Where the result of each call taken and not given a result yet goes, by the number the native app was given for it.
    pending: std.AutoHashMapUnmanaged(u64, native_app.Reply),
    // The number the next call that has a result is given.
    next_reply: u64,
    // The text of the message taken last, which stays valid until the next take.
    taken: ?[]u8,

    //
    // Makes the native app's side of the queue given.
    //
    pub fn init(queue: *MessageQueue) NativeSide {
        return .{
            .queue = queue,
            .pending = .empty,
            .next_reply = 1,
            .taken = null,
        };
    }

    //
    // Releases what it holds, with the UI thread's allocator, but not the queue. The core must have stopped (see stop).
    //
    pub fn deinit(self: *NativeSide, allocator: std.mem.Allocator) void {
        if (self.taken) |text| {
            allocator.free(text);
        }
        self.pending.deinit(allocator);
    }

    //
    // Takes the next message, waiting for one until the timeout passes, or returns null when there is none by then. `.none` waits
    // for as long as it takes, and a timeout of zero does not wait.
    //
    pub fn take(self: *NativeSide, io: std.Io, allocator: std.mem.Allocator, timeout: std.Io.Timeout) ?Taken {
        if (self.taken) |text| {
            allocator.free(text);
            self.taken = null;
        }
        const message = self.queue.take(io, allocator, timeout) orelse {
            return null;
        };
        self.taken = message.text;
        var reply: u64 = 0;
        const kind: native_message.Kind = @enumFromInt(message.from);
        if (kind != .call) {
            return .{
                .kind = kind,
                .text = message.text,
                .reply = 0,
                .reply_to = message.reply_to,
            };
        }
        if (message.reply_to) |queue| {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const call_id = (native_message.callId(arena_state.allocator(), message.text) catch {
                std.debug.panic("the core sent the native app a call that is not JSON: {s}", .{message.text});
            }) orelse {
                std.debug.panic("the core sent the native app a call with a result and no number: {s}", .{message.text});
            };
            reply = self.next_reply;
            self.next_reply += 1;
            self.pending.put(allocator, reply, .{
                .queue = queue,
                .call_id = call_id,
            }) catch @panic("out of memory taking a call");
        }
        return .{
            .kind = kind,
            .text = message.text,
            .reply = reply,
            .reply_to = null,
        };
    }

    //
    // Sends the result of the call taken under the number `reply` to the thread that made it: the text when the native app did what
    // the call names, or the reason when it could not. A number that has no call waiting is error.UnknownReply.
    //
    pub fn result(self: *NativeSide, io: std.Io, allocator: std.mem.Allocator, reply: u64, succeeded: bool, text: []const u8) !void {
        const entry = self.pending.fetchRemove(reply) orelse {
            return error.UnknownReply;
        };
        const target = entry.value;
        const response = try native_message.resultJson(allocator, target.call_id, succeeded, text);
        defer allocator.free(response);
        try target.queue.post(io, 0, response);
    }

    //
    // Waits for the core's main thread to stop, which it has been told to do, and fails every call meanwhile, the ones taken and not
    // given a result yet too, with ShuttingDown, because the native app's UI thread is here and cannot do what they name. Messages for the
    // frontend go to `frontend` when it is given, and are dropped otherwise. It returns once the main thread sends "stopped", the last
    // thing it sends.
    //
    pub fn stop(self: *NativeSide, io: std.Io, allocator: std.mem.Allocator, frontend: ?FrontendSink) void {
        var replies = self.pending.keyIterator();
        while (replies.next()) |reply| {
            const target = self.pending.get(reply.*).?;
            postShuttingDown(io, allocator, target);
        }
        self.pending.clearRetainingCapacity();
        while (true) {
            if (self.taken) |text| {
                allocator.free(text);
                self.taken = null;
            }
            const message = self.queue.take(io, allocator, .none) orelse {
                @panic("the native app's queue closed while the core stopped");
            };
            self.taken = message.text;
            const kind: native_message.Kind = @enumFromInt(message.from);
            if (kind == .deliver) {
                if (frontend) |sink| {
                    sink.deliver(sink.context, allocator, message.text);
                }
                continue;
            }
            if (kind != .call) {
                continue;
            }
            if (message.reply_to) |queue| {
                var arena_state = std.heap.ArenaAllocator.init(allocator);
                defer arena_state.deinit();
                const call_id = (native_message.callId(arena_state.allocator(), message.text) catch null) orelse {
                    std.debug.panic("the core sent the native app a call with a result and no number: {s}", .{message.text});
                };
                postShuttingDown(io, allocator, .{
                    .queue = queue,
                    .call_id = call_id,
                });
                continue;
            }
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const call = native_message.parse(arena_state.allocator(), message.text) catch {
                std.debug.panic("the core sent the native app a call it cannot read: {s}", .{message.text});
            };
            if (call == .stopped) {
                return;
            }
        }
    }

    //
    // Fails a call with ShuttingDown.
    //
    fn postShuttingDown(io: std.Io, allocator: std.mem.Allocator, target: native_app.Reply) void {
        const response = native_message.resultJson(allocator, target.call_id, false, "ShuttingDown") catch @panic("out of memory failing a call while the core stops");
        defer allocator.free(response);
        target.queue.post(io, 0, response) catch @panic("out of memory failing a call while the core stops");
    }
};
