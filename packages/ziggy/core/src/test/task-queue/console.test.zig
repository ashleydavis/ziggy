const std = @import("std");
const utils = @import("ziggy").task_queue.utils;
const console = utils.console;
const MessageQueue = @import("ziggy").core.MessageQueue;
const ThreadAllocator = @import("ziggy").thread_allocator.ThreadAllocator;

test "log and debug write lines to stdout, error and warn to stderr" {
    var stdout_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr_capture.deinit();
    console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer console.setCapture(null, null);

    console.log("one");
    console.debug("two");
    console.@"error"("three");
    console.warn("four");
    console.logFormat("five {d}", .{5});
    console.errorFormat("six {s}", .{"6"});

    try std.testing.expectEqualStrings("one\ntwo\nfive 5\n", stdout_capture.written());
    try std.testing.expectEqualStrings("three\nfour\nsix 6\n", stderr_capture.written());
}

//
// What a forward of the console's lines was given, one "stream|line" each.
//
const Forwarded = struct {
    // The lines.
    lines: std.ArrayList(u8) = .empty,

    fn take(context: ?*anyopaque, stream: console.Stream, line: []const u8) void {
        const self: *Forwarded = @ptrCast(@alignCast(context.?));
        self.lines.print(std.testing.allocator, "{s}|{s}\n", .{ @tagName(stream), line }) catch @panic("out of memory");
    }
};

test "a thread whose console lines are forwarded writes none of them, and the forward gets each with its stream" {
    var stdout_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout_capture.deinit();
    console.setCapture(&stdout_capture.writer, null);
    defer console.setCapture(null, null);
    var forwarded: Forwarded = .{};
    defer forwarded.lines.deinit(std.testing.allocator);
    console.setForward(.{
        .context = &forwarded,
        .function = Forwarded.take,
    });
    console.log("one");
    console.@"error"("two");
    console.setForward(null);
    console.log("three");
    try std.testing.expectEqualStrings("stdout|one\nstderr|two\n", forwarded.lines.items);
    try std.testing.expectEqualStrings("three\n", stdout_capture.written());
}

test "currentForward gives the forward that is set, and null once it is cleared" {
    var forwarded: Forwarded = .{};
    defer forwarded.lines.deinit(std.testing.allocator);
    try std.testing.expect(console.currentForward() == null);
    console.setForward(.{
        .context = &forwarded,
        .function = Forwarded.take,
    });
    const current = console.currentForward().?;
    try std.testing.expect(current.context == @as(?*anyopaque, &forwarded));
    try std.testing.expect(current.function == &Forwarded.take);
    console.setForward(null);
    try std.testing.expect(console.currentForward() == null);
}

//
// Writes a line to the console of a thread of its own, into a capture of that thread's own, and sends the test's thread what the
// capture took on the queue given.
//
fn writeOnAnotherThread(replies: *MessageQueue) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    var capture = std.Io.Writer.Allocating.init(allocator);
    defer capture.deinit();
    console.setCapture(&capture.writer, null);
    console.log("other thread");
    console.setCapture(null, null);
    replies.post(threaded.io(), 0, capture.written()) catch @panic("out of memory replying to the test");
}

test "a capture set on one thread does not take the lines of another" {
    var stdout_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout_capture.deinit();
    console.setCapture(&stdout_capture.writer, null);
    defer console.setCapture(null, null);
    var replies = MessageQueue.init();
    defer replies.deinit();
    const other = try std.Thread.spawn(.{}, writeOnAnotherThread, .{&replies});
    other.join();
    console.log("this thread");
    const other_written = replies.take(std.testing.io, std.testing.allocator, .none).?;
    defer std.testing.allocator.free(other_written.text);
    try std.testing.expectEqualStrings("this thread\n", stdout_capture.written());
    try std.testing.expectEqualStrings("other thread\n", other_written.text);
}
