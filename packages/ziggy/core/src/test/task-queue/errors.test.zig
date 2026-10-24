const std = @import("std");
const utils = @import("ziggy").task_queue.utils;
const errors = utils.errors;
const MessageQueue = @import("ziggy").core.MessageQueue;
const ThreadAllocator = @import("ziggy").thread_allocator.ThreadAllocator;

//
// Helper that throws a plain error.
//
fn failWithValue(value: u32) !void {
    return errors.throwError("Failed with value {d}", .{value});
}

test "throwError records the formatted message" {
    errors.clearError();
    try std.testing.expectError(error.Thrown, failWithValue(42));
    try std.testing.expectEqualStrings("Failed with value 42", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("Error", errors.lastErrorName());
}

test "throwStacklessError records the message under no name" {
    errors.clearError();
    const result: errors.ThrownError!void = errors.throwStacklessError("Missing {s}", .{"file"});
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings("Missing file", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("", errors.lastErrorName());
}

test "throwFatalError records a FatalError" {
    errors.clearError();
    const result: errors.FatalErrorSet!void = errors.throwFatalError("Fatal {s}", .{"problem"});
    try std.testing.expectError(error.FatalError, result);
    try std.testing.expectEqualStrings("Fatal problem", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("FatalError", errors.lastErrorName());
}

test "throwWrappedError keeps the previous message as the cause" {
    errors.clearError();
    failWithValue(1) catch {};
    const result: errors.ThrownError!void = errors.throwWrappedError("Context", .{});
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings("Context: Failed with value 1", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("Failed with value 1", errors.lastErrorCauseMessage());
    try std.testing.expectEqualStrings("WrappedError", errors.lastErrorName());
}

test "throwWrappedError does not fold in an empty cause message" {
    errors.clearError();
    errors.throwWrappedError("Context", .{}) catch {};
    try std.testing.expectEqualStrings("Context", errors.lastErrorMessage());
}

test "throwErrorWithCause keeps the previous error as the cause without folding in its message" {
    errors.clearError();
    failWithValue(3) catch {};
    const result: errors.ThrownError!void = errors.throwErrorWithCause("Context", .{});
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings("Context", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("Failed with value 3", errors.lastErrorCauseMessage());
    try std.testing.expectEqualStrings("Error", errors.lastErrorName());
}

test "errorMessage returns the error name for runtime errors" {
    try std.testing.expectEqualStrings("FileNotFound", errors.errorMessage(error.FileNotFound));
}

test "errorMessage returns the recorded message for thrown errors" {
    failWithValue(7) catch |err| {
        try std.testing.expectEqualStrings("Failed with value 7", errors.errorMessage(err));
    };
}

test "throwWrappedError keeps the whole cause chain" {
    errors.clearError();
    failWithValue(1) catch {};
    errors.throwWrappedError("Middle", .{}) catch {};
    errors.throwWrappedError("Outer", .{}) catch {};
    try std.testing.expectEqualStrings("Outer: Middle: Failed with value 1", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("Middle: Failed with value 1", errors.lastErrorCauseMessage());
    var cause_chain = errors.lastErrorCauseChain();
    try std.testing.expectEqualStrings("Middle: Failed with value 1", cause_chain.next().?);
    try std.testing.expectEqualStrings("Failed with value 1", cause_chain.next().?);
    try std.testing.expect(cause_chain.next() == null);
}

test "lastErrorCauseChain is empty when there is no cause" {
    failWithValue(2) catch {};
    var cause_chain = errors.lastErrorCauseChain();
    try std.testing.expect(cause_chain.next() == null);
}

//
// A captured error as the JSON text one thread sends another: the fields of an ErrorRecord that hold something.
//
const ErrorJson = struct {
    // The error message.
    message: []const u8,
    // The messages of the cause chain, as ErrorRecord.cause_buffer holds them.
    causes: []const u8,
    // The error class name.
    name: []const u8,
    // The error class names of the cause chain.
    causeNames: []const []const u8,
};

//
// Throws an error on a thread of its own, captures it into a record of its own and sends the test's thread a copy of the record on
// the queue given, as the JSON text of an ErrorJson.
//
fn throwOnThread(replies: *MessageQueue) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    failWithValue(99) catch {};
    const record = allocator.create(errors.ErrorRecord) catch @panic("out of memory");
    defer allocator.destroy(record);
    errors.captureError(record);
    const text = std.json.Stringify.valueAlloc(allocator, ErrorJson{
        .message = record.message_buffer[0..record.message_length],
        .causes = record.cause_buffer[0..record.cause_length],
        .name = record.name,
        .causeNames = record.cause_names[0..record.cause_name_count],
    }, .{}) catch @panic("out of memory");
    defer allocator.free(text);
    replies.post(threaded.io(), 0, text) catch @panic("out of memory replying to the test");
}

test "captureError and restoreError move an error between threads" {
    errors.clearError();
    var replies = MessageQueue.init();
    defer replies.deinit();
    const thread = try std.Thread.spawn(.{}, throwOnThread, .{&replies});
    thread.join();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The restored error's names are in the arena, so the error is cleared before the arena is freed.
    defer errors.clearError();
    const captured = replies.take(std.testing.io, arena, .none).?;
    const copy = try std.json.parseFromSliceLeaky(ErrorJson, arena, captured.text, .{});
    const record = try std.testing.allocator.create(errors.ErrorRecord);
    defer std.testing.allocator.destroy(record);
    record.* = .{};
    @memcpy(record.message_buffer[0..copy.message.len], copy.message);
    record.message_length = copy.message.len;
    @memcpy(record.cause_buffer[0..copy.causes.len], copy.causes);
    record.cause_length = copy.causes.len;
    record.name = copy.name;
    @memcpy(record.cause_names[0..copy.causeNames.len], copy.causeNames);
    record.cause_name_count = copy.causeNames.len;
    try std.testing.expectEqualStrings("", errors.lastErrorMessage());
    errors.restoreError(record);
    try std.testing.expectEqualStrings("Failed with value 99", errors.lastErrorMessage());
}

test "lastErrorCauseNames names each cause of the chain, nearest first" {
    errors.clearError();
    errors.throwFatalError("root", .{}) catch {};
    errors.throwWrappedError("Middle", .{}) catch {};
    errors.throwErrorWithCause("Outer", .{}) catch {};
    const cause_names = errors.lastErrorCauseNames();
    try std.testing.expectEqual(@as(usize, 2), cause_names.len);
    try std.testing.expectEqualStrings("WrappedError", cause_names[0]);
    try std.testing.expectEqualStrings("FatalError", cause_names[1]);

    // A new error without a cause has none.
    failWithValue(3) catch {};
    try std.testing.expectEqual(@as(usize, 0), errors.lastErrorCauseNames().len);
}

test "errorToString gives String(error): the name JavaScript gives the error and its message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    errors.recordError("RangeError", "stdout maxBuffer length exceeded", .{});
    try std.testing.expectEqualStrings("RangeError: stdout maxBuffer length exceeded", try errors.errorToString(allocator, error.Thrown));

    try std.testing.expectEqual(error.FatalError, errors.throwFatalError("No database", .{}));
    try std.testing.expectEqualStrings("FatalError: No database", try errors.errorToString(allocator, error.FatalError));

    // A WrappedError sets no name, so it is an Error; so is an error without a stack.
    try std.testing.expectEqual(error.Thrown, errors.throwWrappedError("Outer", .{}));
    try std.testing.expectEqualStrings("Error: Outer: No database", try errors.errorToString(allocator, error.Thrown));
    try std.testing.expectEqual(error.Thrown, errors.throwStacklessError("stream closed", .{}));
    try std.testing.expectEqualStrings("Error: stream closed", try errors.errorToString(allocator, error.Thrown));

    // A runtime error is an Error with the Zig error name as its message, and an empty message leaves the name alone.
    try std.testing.expectEqualStrings("Error: FileNotFound", try errors.errorToString(allocator, error.FileNotFound));
    errors.recordError("TypeError", "", .{});
    try std.testing.expectEqualStrings("TypeError", try errors.errorToString(allocator, error.Thrown));
}
