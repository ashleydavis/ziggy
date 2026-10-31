const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils");
const ziggy_log = @import("log");
const standard_streams = ziggy_log.standard_streams;
const MessageQueue = @import("ziggy").core.MessageQueue;
const ThreadAllocator = @import("utils").thread_allocator.ThreadAllocator;

//
// How much the writer sends through the pipe: many times the pipe's quota, so the pipe fills and writes
// have to wait for the reader.
//
const PIPE_TEST_BYTE_COUNT: usize = 256 * 1024;

//
// What the slow reader of the pipe test found.
//
const IPipeReaderResult = struct {
    // The number of bytes the reader took out of the pipe before it was closed.
    byteCount: usize = 0,

    // The error the reader hit, if any.
    readError: ?anyerror = null,
};

//
// What the slow reader of the pipe test sends the test's thread: the number of bytes it took and the number of the error it hit, or
// null. An error's number is the same on every thread of the process.
//
const PipeReaderReport = struct {
    byteCount: usize,
    readError: ?ErrorNumber,
};

//
// The number of an error.
//
const ErrorNumber = std.meta.Int(.unsigned, @bitSizeOf(anyerror));

//
// Waits before reading, then reads the pipe to its end, closes it and sends the test's thread, on the queue given, how many bytes came
// through, as the JSON text of a PipeReaderReport. It owns the read end from when it starts.
//
fn readPipeSlowly(readEnd: std.Io.File, replies: *MessageQueue) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();
    defer readEnd.close(io);

    // Waits so the pipe is full while the writer is still writing.
    utils.sleep.sleep(io, 300) catch {};
    var buffer: [4096]u8 = undefined;
    var fileReader = readEnd.readerStreaming(io, &buffer);
    var report: PipeReaderReport = .{
        .byteCount = 0,
        .readError = null,
    };
    if (fileReader.interface.discardRemaining()) |count| {
        report.byteCount = count;
    }
    else |err| {
        report.readError = @intFromError(err);
    }
    const text = std.json.Stringify.valueAlloc(allocator, report, .{}) catch @panic("out of memory");
    defer allocator.free(text);
    replies.post(io, 0, text) catch @panic("out of memory replying to the test");
}

test "the standard streams are the process's own handles" {
    try std.testing.expectEqual(std.Io.File.stdin().handle, standard_streams.stdin().handle);
    try std.testing.expectEqual(std.Io.File.stdout().handle, standard_streams.stdout().handle);
    try std.testing.expectEqual(std.Io.File.stderr().handle, standard_streams.stderr().handle);
}

test "a file opened for synchronous I/O keeps the synchronous description" {
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();
    const io = std.testing.io;
    const file = try tmpDir.dir.createFile(io, "synchronous.txt", .{});
    defer file.close(io);

    const described = standard_streams.withActualMode(file);

    try std.testing.expectEqual(file.handle, described.handle);
    try std.testing.expect(!described.flags.nonblocking);
}

test "a slow reader of an asynchronous pipe gets every byte written to it" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const windows = std.os.windows;
    const io = std.testing.io;

    // The same kind of pipe an MSYS2 or Cygwin shell gives a native program as its standard output: the
    // program's end is opened for asynchronous I/O. Here the test reads the other end itself.
    const handles = try std.testing.io_instance.windowsCreatePipe(.{
        .server = .{
            .mode = .{
                .IO = .SYNCHRONOUS_NONALERT,
            },
        },
        .client = .{
            .mode = .{
                .IO = .ASYNCHRONOUS,
            },
        },
        .inbound = true,
    });
    const readEnd: std.Io.File = .{
        .handle = handles[0],
        .flags = .{
            .nonblocking = false,
        },
    };
    // The reader's thread owns the read end once it has started, and closes it.
    var read_end_given = false;
    defer if (!read_end_given) readEnd.close(io);

    // Described the way std.Io.File.stdout() describes every standard handle, then corrected.
    const writeEnd = standard_streams.withActualMode(.{
        .handle = handles[1],
        .flags = .{
            .nonblocking = false,
        },
    });
    try std.testing.expect(writeEnd.flags.nonblocking);

    var replies = MessageQueue.init();
    defer replies.deinit();
    const reader = try std.Thread.spawn(.{}, readPipeSlowly, .{
        readEnd,
        &replies,
    });
    read_end_given = true;

    const payload = try std.testing.allocator.alloc(u8, PIPE_TEST_BYTE_COUNT);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    var buffer: [1024]u8 = undefined;
    var fileWriter = writeEnd.writerStreaming(io, &buffer);
    const writeResult = fileWriter.interface.writeAll(payload);
    const flushResult = fileWriter.interface.flush();
    windows.CloseHandle(writeEnd.handle);
    reader.join();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const reported = replies.take(io, arena_state.allocator(), .none).?;
    const report = try std.json.parseFromSliceLeaky(PipeReaderReport, arena_state.allocator(), reported.text, .{});
    const result: IPipeReaderResult = .{
        .byteCount = report.byteCount,
        .readError = if (report.readError) |number| @errorFromInt(number) else null,
    };

    try writeResult;
    try flushResult;
    try std.testing.expectEqual(@as(?anyerror, null), result.readError);
    try std.testing.expectEqual(PIPE_TEST_BYTE_COUNT, result.byteCount);
}
