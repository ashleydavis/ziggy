//
// The template's log files, which it writes in the logs directory of its data directory from when the backend is created until it is
// destroyed.
//

const std = @import("std");
const ziggy = @import("ziggy");
const app = @import("ziggy-template-backend");

const FakeNativeApp = ziggy.fake_native_app.FakeNativeApp;

test "the template writes its two log files in its data directory, with its header and footer, the lines its hello world code logs and none of another thread's lines" {
    const console_log = ziggy.log.mute_log.MuteLog.init();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const data_dir = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(2, 2);
    config.data_dir = data_dir.ptr;
    try native_app.start(std.testing.io, std.testing.allocator, config, app.app);
    console_log.info("not on the template's main thread");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"hello-world\",\"data\":{\"name\":\"world\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"greeting\":\"Hello world, from Zig on");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"t1\",\"taskType\":\"hello-world-task\",\"source\":\"hello\",\"data\":null}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"succeeded\"");
    native_app.stop(std.testing.io, std.testing.allocator);

    var logs_dir = try tmp.dir.openDir(std.testing.io, "logs", .{
        .iterate = true,
    });
    defer logs_dir.close(std.testing.io);
    var log_names: std.ArrayList([]u8) = .empty;
    defer {
        for (log_names.items) |name| {
            std.testing.allocator.free(name);
        }
        log_names.deinit(std.testing.allocator);
    }
    var iterator = logs_dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        try log_names.append(std.testing.allocator, try std.testing.allocator.dupe(u8, entry.name));
    }
    try std.testing.expectEqual(@as(usize, 2), log_names.items.len);
    for (log_names.items) |name| {
        try std.testing.expect(std.mem.startsWith(u8, name, "ziggy-template-"));
        if (!std.mem.endsWith(u8, name, "-errors.log")) {
            const written = try logs_dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1024 * 1024));
            defer std.testing.allocator.free(written);
            try std.testing.expect(std.mem.startsWith(u8, written, "=" ** 80 ++ "\nZiggy template\n"));
            try std.testing.expect(std.mem.indexOf(u8, written, "\nVersion: ") == null);
            try std.testing.expect(std.mem.indexOf(u8, written, "\n--- Log End ---\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, written, "not on the template's main thread") == null);
            // The two lines the hello world code logs: the message handler's on the main thread, and the task's, tagged with its worker.
            try std.testing.expect(std.mem.indexOf(u8, written, "] [INFO] Greeting world\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, written, "] [INFO] [Worker ") != null);
            try std.testing.expect(std.mem.indexOf(u8, written, "] The hello world task is running\n") != null);
        }
    }
}
