const std = @import("std");
const ziggy = @import("ziggy");

const MessageQueue = ziggy.message_queue.MessageQueue;
const ThreadAllocator = ziggy.utils.thread_allocator.ThreadAllocator;

const io = std.testing.io;

test "messages are taken in the order they were posted, each with who sent it and a copy of its text" {
    var queue = MessageQueue.init();
    defer queue.deinit();
    var text = [_]u8{ 'o', 'n', 'e' };
    try queue.post(io, 7, &text);
    // The queue keeps a copy, so changing the poster's text afterwards changes nothing in the queue.
    text[0] = 'x';
    try queue.post(io, 8, "two");
    const first = queue.tryTake(io, std.testing.allocator).?;
    defer std.testing.allocator.free(first.text);
    const second = queue.tryTake(io, std.testing.allocator).?;
    defer std.testing.allocator.free(second.text);
    try std.testing.expectEqual(@as(u32, 7), first.from);
    try std.testing.expectEqualStrings("one", first.text);
    try std.testing.expectEqual(@as(u32, 8), second.from);
    try std.testing.expectEqualStrings("two", second.text);
    try std.testing.expect(queue.tryTake(io, std.testing.allocator) == null);
}

test "a message carries the queue its reply goes to" {
    var queue = MessageQueue.init();
    defer queue.deinit();
    var replies = MessageQueue.init();
    defer replies.deinit();
    try queue.postReplyTo(io, 1, "request", &replies);
    try queue.post(io, 1, "tell");
    const requested = queue.tryTake(io, std.testing.allocator).?;
    defer std.testing.allocator.free(requested.text);
    const told = queue.tryTake(io, std.testing.allocator).?;
    defer std.testing.allocator.free(told.text);
    try std.testing.expect(requested.reply_to == &replies);
    try std.testing.expect(told.reply_to == null);
}

//
// Posts the numbers from 0 to the count, in order, from the sender given.
//
fn postNumbers(queue: *MessageQueue, sender: u32, count: usize) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded = ownIo(thread_allocator.allocator());
    defer threaded.deinit();
    var buffer: [32]u8 = undefined;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const text = std.fmt.bufPrint(&buffer, "{d}", .{index}) catch unreachable;
        queue.post(threaded.io(), sender, text) catch @panic("out of memory posting");
    }
}

//
// An Io of the calling thread's own, for a thread a test starts, with the thread's own allocator.
//
fn ownIo(allocator: std.mem.Allocator) std.Io.Threaded {
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    return threaded;
}

test "messages posted by several threads at once all arrive, and each sender's arrive in the order it posted them" {
    var queue = MessageQueue.init();
    defer queue.deinit();
    const senders = 4;
    const count = 2000;
    var threads: [senders]std.Thread = undefined;
    for (&threads, 0..) |*thread, sender| {
        thread.* = try std.Thread.spawn(.{}, postNumbers, .{ &queue, @as(u32, @intCast(sender)), count });
    }
    var next = [_]usize{0} ** senders;
    var received: usize = 0;
    while (received < senders * count) : (received += 1) {
        // A lost message never comes, so the wait for each one gives up after ten seconds.
        const message = queue.take(io, std.testing.allocator, .{
            .duration = .{
                .raw = .fromMilliseconds(10_000),
                .clock = .awake,
            },
        }) orelse {
            for (threads) |thread| {
                thread.join();
            }
            return error.MessageLost;
        };
        defer std.testing.allocator.free(message.text);
        const number = try std.fmt.parseInt(usize, message.text, 10);
        try std.testing.expectEqual(next[message.from], number);
        next[message.from] += 1;
    }
    for (threads) |thread| {
        thread.join();
    }
    for (next) |posted| {
        try std.testing.expectEqual(@as(usize, count), posted);
    }
    try std.testing.expect(queue.tryTake(io, std.testing.allocator) == null);
}

//
// Waits a little, then posts one message, so a thread waiting on the queue is woken by it.
//
fn postLater(queue: *MessageQueue) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded = ownIo(thread_allocator.allocator());
    defer threaded.deinit();
    threaded.io().sleep(.fromMilliseconds(50), .awake) catch {};
    queue.post(threaded.io(), 3, "late") catch @panic("out of memory posting");
}

test "a thread waiting for a message wakes when one is posted" {
    var queue = MessageQueue.init();
    defer queue.deinit();
    const poster = try std.Thread.spawn(.{}, postLater, .{&queue});
    defer poster.join();
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    // The wait would end after five seconds anyway, when the message would be found; woken, it ends soon after the post.
    const message = queue.take(io, std.testing.allocator, .{
        .duration = .{
            .raw = .fromMilliseconds(5000),
            .clock = .awake,
        },
    }).?;
    defer std.testing.allocator.free(message.text);
    const waited = started.untilNow(std.testing.io).raw.toMilliseconds();
    try std.testing.expectEqualStrings("late", message.text);
    try std.testing.expect(waited < 2000);
}

test "a wait with a timeout on an empty queue ends with no message once the timeout has passed" {
    var queue = MessageQueue.init();
    defer queue.deinit();
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const message = queue.take(io, std.testing.allocator, .{
        .duration = .{
            .raw = .fromMilliseconds(30),
            .clock = .awake,
        },
    });
    const waited = started.untilNow(std.testing.io).raw.toMilliseconds();
    try std.testing.expect(message == null);
    try std.testing.expect(waited >= 30);
}

test "a closed queue drops what is posted to it, gives what it held, then ends waits at once" {
    var queue = MessageQueue.init();
    defer queue.deinit();
    try queue.post(io, 1, "kept");
    queue.close(io);
    try queue.post(io, 1, "dropped");
    const kept = queue.take(io, std.testing.allocator, .none).?;
    defer std.testing.allocator.free(kept.text);
    try std.testing.expectEqualStrings("kept", kept.text);
    try std.testing.expect(queue.take(io, std.testing.allocator, .none) == null);
}

test "a queue reports whether it is closed" {
    var queue = MessageQueue.init();
    defer queue.deinit();
    try std.testing.expect(!queue.isClosed(io));
    queue.close(io);
    try std.testing.expect(queue.isClosed(io));
}

test "a taken message's text is a copy in memory from the allocator the taking thread gives" {
    var queue = MessageQueue.init();
    defer queue.deinit();
    try queue.post(io, 1, "copied out");
    var buffer: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const message = queue.tryTake(io, fixed.allocator()).?;
    try std.testing.expectEqualStrings("copied out", message.text);
    try std.testing.expect(fixed.ownsSlice(message.text));
}

test "the messages nobody took are freed with the queue" {
    // The queue's own allocator logs an error, which fails the test, for any of them left unfreed.
    var queue = MessageQueue.init();
    try queue.post(io, 1, "never taken");
    try queue.post(io, 2, "nor this");
    queue.deinit();
}
