const std = @import("std");
const ziggy = @import("ziggy");
const template = @import("ziggy-test-app-backend");

//
// The media server's functions, which are in handlers.zig.
//
const media_server = template.handlers;

const FakeNativeApp = ziggy.fake_native_app.FakeNativeApp;

//
// Creates a backend for the test app on the fake native app.
//
fn createCore(native_app: *FakeNativeApp) !void {
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(3, 4), template.app);
}

//
// Creates a backend for the test app on the fake native app, with the data directory given.
//
fn createCoreInDataDir(native_app: *FakeNativeApp, data_dir: [*:0]const u8) !void {
    var config = native_app.config(3, 4);
    config.data_dir = data_dir;
    try native_app.start(std.testing.io, std.testing.allocator, config, template.app);
}

//
// Creates a backend on the fake native app, which handles dialogs with a callback which returns the arguments it was called with as its result.
//
fn createPickersCore(native_app: *FakeNativeApp) !void {
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(2, 2), template.app);
}

//
// Queues a background task with the id, type, source and data given, as the frontend would with the add-task system message.
//
fn addTask(native_app: *FakeNativeApp, id: []const u8, task_type: []const u8, source: []const u8, data: []const u8) !void {
    const message = try ziggy.json.stringify(std.testing.allocator, .{
        .kind = "system",
        .name = "add-task",
        .data = .{
            .taskId = id,
            .taskType = task_type,
            .source = source,
            .data = ziggy.json.Raw{ .text = data },
            .priority = "background",
        },
    });
    defer std.testing.allocator.free(message);
    native_app.sendMessage(std.testing.allocator, message);
}

//
// Waits for a message containing the text and returns its index among the messages the fake native app has received.
//
fn indexOfMessage(native_app: *FakeNativeApp, text: []const u8) !usize {
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, text);
    return native_app.indexOfContaining(std.testing.io, std.testing.allocator, text).?;
}

//
// Fetches a path from the server on the port with an HTTP request, and returns everything the server sent until it closed.
//
fn fetch(allocator: std.mem.Allocator, port: u16, request: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    return try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}

//
// Starts the media-server task, waits for its "media-server" event and returns the port in it.
//
fn startServer(native_app: *FakeNativeApp) !u16 {
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"media-1\",\"taskType\":\"media-server\",\"source\":\"media\",\"data\":null,\"priority\":\"background\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"type\":\"media-server\"");
    const message = try native_app.messageAt(std.testing.io, std.testing.allocator, native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"type\":\"media-server\"").?);
    defer std.testing.allocator.free(message);
    const marker = "\"port\":";
    const start = std.mem.indexOf(u8, message, marker).? + marker.len;
    var end = start;
    while (end < message.len and std.ascii.isDigit(message[end])) {
        end += 1;
    }
    return try std.fmt.parseInt(u16, message[start..end], 10);
}

//
// Messages, the hello tasks and the background tasks.
//

test "ping replies with the Zig version, the platform and an echo of the payload" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"ping\",\"data\":{\"hello\":\"world\"}}");
    const reply = try native_app.messageAt(std.testing.io, std.testing.allocator, 0);
    defer std.testing.allocator.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reply, .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?;
    try std.testing.expectEqualStrings(@import("builtin").zig_version_string, data.object.get("zigVersion").?.string);
    try std.testing.expectEqualStrings(@tagName(@import("builtin").os.tag), data.object.get("os").?.string);
    try std.testing.expectEqualStrings(@tagName(@import("builtin").cpu.arch), data.object.get("arch").?.string);
    try std.testing.expectEqualStrings("world", data.object.get("echo").?.object.get("hello").?.string);
}
test "payload-stats reports the length and checksum of a multi-megabyte payload" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const payload = try std.testing.allocator.alloc(u8, 5 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    const message = try ziggy.json.stringify(std.testing.allocator, .{
        .kind = "app",
        .id = 1,
        .name = "payload-stats",
        .data = .{
            .text = payload,
        },
    });
    defer std.testing.allocator.free(message);
    try native_app.send(std.testing.io, std.testing.allocator, message);
    const reply = try native_app.messageAt(std.testing.io, std.testing.allocator, 0);
    defer std.testing.allocator.free(reply);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "\"length\":{d},\"crc32\":{d}", .{ payload.len, std.hash.Crc32.hash(payload) });
    defer std.testing.allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, reply, expected) != null);
}
test "payload-stats counts the bytes of text with non-ASCII characters" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"payload-stats\",\"data\":{\"text\":\"é世界😀\"}}");
    const reply = try native_app.messageAt(std.testing.io, std.testing.allocator, 0);
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"length\":12,") != null);
}
test "payload-stats without text is an error reply" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"payload-stats\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"text\\\" is missing\"}");
}
test "file-roundtrip writes a file in the data directory and reads it back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const data_dir = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCoreInDataDir(&native_app, data_dir.ptr);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"file-roundtrip\",\"data\":{\"text\":\"kept \\u00e9\"}}");
    const reply = try native_app.messageAt(std.testing.io, std.testing.allocator, 0);
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"text\":\"kept é\"") != null);
    var buffer: [64]u8 = undefined;
    const written = try tmp.dir.readFile(std.testing.io, "ziggy-test-app-roundtrip.txt", &buffer);
    try std.testing.expectEqualStrings("kept é", written);
}
test "the test app does not start when its data directory cannot hold its log files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "a-file",
        .data = "not a directory",
    });
    var path_buffer: [256]u8 = undefined;
    const data_dir = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/a-file/data", .{tmp.sub_path});
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try std.testing.expect(std.meta.isError(createCoreInDataDir(&native_app, data_dir.ptr)));
}

//
// Reads the one log file in the logs directory of a data directory whose name starts with the prefix and does not end in
// "-errors.log", or the error log file when `errors` is true.
//
fn readLogFile(allocator: std.mem.Allocator, data_dir: []const u8, errors: bool) ![]u8 {
    const logs_dir_path = try std.fs.path.join(allocator, &.{ data_dir, "logs" });
    defer allocator.free(logs_dir_path);
    var logs_dir = try std.Io.Dir.cwd().openDir(std.testing.io, logs_dir_path, .{
        .iterate = true,
    });
    defer logs_dir.close(std.testing.io);
    var iterator = logs_dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        const is_error_file = std.mem.endsWith(u8, entry.name, "-errors.log");
        if (std.mem.startsWith(u8, entry.name, "ziggy-test-app-") and is_error_file == errors) {
            return logs_dir.readFileAlloc(std.testing.io, entry.name, allocator, .limited(1024 * 1024));
        }
    }
    return error.NoLogFile;
}

test "the test app writes its log files in its data directory, headed with its app.zon title, with ping's line and the tasks' lines tagged with their worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const data_dir = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCoreInDataDir(&native_app, data_dir.ptr);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"ping\",\"data\":null}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true");
    try addTask(&native_app, "s1", "hello-short", "src", "null");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"s1\",\"status\":\"succeeded\"");
    try addTask(&native_app, "f1", "hello-fail", "src", "null");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"f1\",\"status\":\"failed\"");
    native_app.stop(std.testing.io, std.testing.allocator);
    const written = try readLogFile(std.testing.allocator, data_dir, false);
    defer std.testing.allocator.free(written);
    const errors_written = try readLogFile(std.testing.allocator, data_dir, true);
    defer std.testing.allocator.free(errors_written);
    try std.testing.expect(std.mem.startsWith(u8, written, "=" ** 80 ++ "\nZiggy test app\n"));
    try std.testing.expect(std.mem.indexOf(u8, written, "\nVersion: ") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "] [INFO] ping received\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "] [INFO] [Worker ") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "] the short task is running\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors_written, "] [ERROR] [Worker ") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors_written, "] the failing task is failing\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\n--- Log End ---\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors_written, "\n--- Error Log End ---\n") != null);
}

test "a line the frontend logs reaches the test app's log files tagged Frontend" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const data_dir = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCoreInDataDir(&native_app, data_dir.ptr);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"log\",\"data\":{\"level\":\"info\",\"message\":\"the page opened\",\"error\":null}}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"log\",\"data\":{\"level\":\"exception\",\"message\":\"the page failed\",\"error\":\"Error: at line 4\"}}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"log\",\"data\":{\"level\":\"tool\",\"message\":\"magick\",\"toolData\":{\"stdout\":\"converted\"}}}");
    native_app.stop(std.testing.io, std.testing.allocator);
    const written = try readLogFile(std.testing.allocator, data_dir, false);
    defer std.testing.allocator.free(written);
    const errors_written = try readLogFile(std.testing.allocator, data_dir, true);
    defer std.testing.allocator.free(errors_written);
    try std.testing.expect(std.mem.indexOf(u8, written, "] [INFO] [Frontend] the page opened\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "] [EXCEPTION] [Frontend] the page failed\nError: at line 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors_written, "] [EXCEPTION] [Frontend] the page failed\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "] [TOOL] [Frontend] == magick stdout ==\nconverted\n") != null);
}

test "a line the frontend logs at a level the core does not know is a core-error event" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"log\",\"data\":{\"level\":\"shout\",\"message\":\"x\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"UnknownLogLevel\"}}");
}
test "the fail message replies with an error" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"fail\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"ExampleFailure\"}");
}
test "hello-short sends an output event and a job-progress event then completes" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "t1", "hello-short", "src", "{\"job\":{\"id\":\"job-1\",\"name\":\"Short job\",\"cancelSource\":\"src\"}}");
    const output = try indexOfMessage(&native_app, "\"source\":\"src\",\"data\":{\"type\":\"output\",\"text\":\"hello from a short task\"}");
    const progress = try indexOfMessage(&native_app, "\"source\":\"src\",\"data\":{\"type\":\"job-progress\",\"job\":{\"id\":\"job-1\",\"name\":\"Short job\",\"cancelSource\":\"src\"},\"startedAt\":");
    const completed = try indexOfMessage(&native_app, "\"status\":\"succeeded\",\"outputs\":\"short task done\"");
    try std.testing.expect(output < progress);
    try std.testing.expect(progress < completed);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"progressMessage\":\"short task working\"}");
}
test "a job-progress event leaves out the cancel source when the job has none" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "t1", "hello-short", "src", "{\"job\":{\"id\":\"job-1\",\"name\":\"Short job\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"job\":{\"id\":\"job-1\",\"name\":\"Short job\"},\"startedAt\"");
}
test "a task with no job sends no job-progress event" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "t1", "hello-short", "src", "{}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"succeeded\"");
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "job-progress"));
}
test "hello-long sends output and progress at every step, starts its children and waits for them" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "long", "hello-long", "src", "{\"durationMs\":200,\"stepMs\":50,\"children\":3,\"job\":{\"id\":\"job-1\",\"name\":\"Long job\",\"cancelSource\":\"src\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"result\":{\"taskId\":\"long\",\"status\":\"succeeded\",\"outputs\":{\"steps\":4,\"children\":3}");
    try std.testing.expectEqual(@as(usize, 4), native_app.countContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"long\",\"source\":\"src\",\"data\":{\"type\":\"output\",\"text\":\"long task step"));
    try std.testing.expectEqual(@as(usize, 3), native_app.countContaining(std.testing.io, std.testing.allocator, "child long.c"));
    try std.testing.expectEqual(@as(usize, 3), native_app.countContaining(std.testing.io, std.testing.allocator, "\"status\":\"succeeded\",\"outputs\":{\"index\":"));
    // The children report under the parent's job id.
    try std.testing.expect(native_app.countContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"long.c0\",\"source\":\"src\",\"data\":{\"type\":\"job-progress\",\"job\":{\"id\":\"job-1\"") == 1);
    // The parent's completion is the last thing that happens.
    try std.testing.expect(native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"result\":{\"taskId\":\"long\",\"status\"").? > native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"result\":{\"taskId\":\"long.c2\",\"status\"").?);
}
test "hello-long with no children and more children than steps both complete" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "a", "hello-long", "src", "{\"durationMs\":50,\"stepMs\":50,\"children\":0}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"result\":{\"taskId\":\"a\",\"status\":\"succeeded\",\"outputs\":{\"steps\":1,\"children\":0}");
    try addTask(&native_app, "b", "hello-long", "src", "{\"durationMs\":50,\"stepMs\":50,\"children\":5}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"result\":{\"taskId\":\"b\",\"status\":\"succeeded\",\"outputs\":{\"steps\":1,\"children\":5}");
}
test "cancelling hello-long stops it early and its children are cancelled" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "long", "hello-long", "src", "{\"durationMs\":60000,\"stepMs\":20,\"children\":2}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "long task step 3");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"cancel-tasks\",\"data\":\"src\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"failed\",\"error\":{\"message\":\"Cancelled\"},\"errorMessage\":\"Cancelled\"");
    try std.testing.expect(native_app.countContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"long\",\"source\":\"src\",\"data\":{\"type\":\"output\",\"text\":\"long task step") < 100);
}
test "hello-fail completes as failed" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "t1", "hello-fail", "src", "null");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"failed\",\"error\":{\"message\":\"HelloFailure\"},\"errorMessage\":\"HelloFailure\"");
}
test "os-version returns what the native app's os-version call gives" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "t1", "os-version", "src", "null");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"succeeded\",\"outputs\":\"Test OS 1.0\"");
}
test "os-version fails clearly when the native app provides no os-version call" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.has_os_version = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, template.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "t1", "os-version", "src", "null");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"failed\",\"error\":{\"message\":\"NativeCallMissing\"},\"errorMessage\":\"NativeCallMissing\"");
}
test "the keep-alive background task counts in a file in the data directory and has the native app keep the app running, and the normal one does not" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(data_dir);
    const data_dir_z = try std.testing.allocator.dupeZ(u8, data_dir);
    defer std.testing.allocator.free(data_dir_z);

    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCoreInDataDir(&native_app, data_dir_z.ptr);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "bk", "background-keep-alive", "src", "{\"file\":\"keep.txt\",\"durationMs\":300}");
    try addTask(&native_app, "bn", "background-normal", "src", "{\"file\":\"normal.txt\",\"durationMs\":300}");
    _ = try indexOfMessage(&native_app, "task-completed\",\"data\":{\"taskId\":\"bk\"");
    _ = try indexOfMessage(&native_app, "task-completed\",\"data\":{\"taskId\":\"bn\"");

    const kept = try tmp.dir.readFileAlloc(std.testing.io, "keep.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(kept);
    try std.testing.expect(try std.fmt.parseInt(u32, std.mem.trim(u8, kept, "\n"), 10) >= 2);
    const normal = try tmp.dir.readFileAlloc(std.testing.io, "normal.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(normal);
    try std.testing.expect(try std.fmt.parseInt(u32, std.mem.trim(u8, normal, "\n"), 10) >= 2);

    // The main thread tells the native app to stop keeping the app running after it sends the last task-completed event, and has
    // done so by the time it has handled a message sent now.
    try native_app.handled(std.testing.io, std.testing.allocator);
    const keep_alive_calls = try native_app.keepAliveCalls(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(keep_alive_calls);
    try std.testing.expectEqualStrings("[true,false]", keep_alive_calls);
}
test "file-roundtrip without text is an error reply" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"file-roundtrip\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"text\\\" is missing\"}");
}
test "os-version fails clearly when the native app cannot give the version" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), template.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.setResult(std.testing.io, std.testing.allocator, "os-version", false, "The version could not be read.");
    try addTask(&native_app, "t1", "os-version", "src", "null");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"failed\",\"error\":{\"message\":\"NativeCallFailed\"},\"errorMessage\":\"NativeCallFailed\"");
}
test "a background task without a file to count in fails with MissingFile" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "bm", "background-normal", "src", "{\"durationMs\":300}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"errorMessage\":\"MissingFile\"");
}
test "a message of a name the test app does not know is an UnknownMessageName error" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"no-such-name\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"UnknownMessageName\"}");
}
test "a message with no name, or an empty one, is refused with MissingMessageName" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"data\":{\"text\":\"x\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"MissingMessageName\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"\",\"data\":\"a string, not an object\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":false,\"error\":\"MissingMessageName\"}");
}
//
// The error describer.
//

test "the refuse message's error reaches the UI as the sentence the test app's describer gives" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"refuse\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"The test app refused, as the request told it to.\"}");
}
test "an error the describer has no sentence for is replied to by name" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"fail\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"ExampleFailure\"}");
}
//
// Tasks queued and cancelled from the app's code.
//

test "queue-from-app queues a task from the app's code, tells the UI with an app event, and the task runs" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"queue-from-app\",\"data\":{\"source\":\"app-source\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"queued-from-app\",\"queued\":\"from-app-app-source\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true,\"data\":\"from-app-app-source\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"from-app-app-source\",\"status\":\"succeeded\"");
}
test "queue-from-app and cancel-from-app without a source are error replies" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"queue-from-app\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"source\\\" is missing\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"cancel-from-app\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"source\\\" is missing\"}");
}
test "cancel-from-app cancels, from the app's code, a task the UI queued" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "long", "hello-long", "to-cancel", "{\"durationMs\":60000,\"stepMs\":10}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "long task step 1");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"cancel-from-app\",\"data\":{\"source\":\"to-cancel\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"long\",\"status\":\"failed\",\"error\":{\"message\":\"Cancelled\"}");
}
//
// Tasks that work through their task context.
//

test "describe-self replies with the task's id, type, source and child limit" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "d1", "describe-self", "self-source", "null");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"outputs\":{\"taskId\":\"d1\",\"taskType\":\"describe-self\",\"source\":\"self-source\",\"maxConcurrentChildTasks\":4}");
}
test "run-in-turn runs its children one after another and reports how each ended" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "r1", "run-in-turn", "turn-source", "{\"children\":3}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"outputs\":{\"ran\":3,\"statuses\":[\"succeeded\",\"succeeded\",\"succeeded\"]}");
}
test "run-in-turn stops starting children once it is cancelled" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "r2", "run-in-turn", "turn-cancel", "{\"children\":100000}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "child 1 running");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"cancel-tasks\",\"data\":\"turn-cancel\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "run-in-turn stopped after ");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"r2\",\"status\":\"failed\",\"error\":{\"message\":\"Cancelled\"}");
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "child 99999 running"));
}
//
// The file and folder pickers.
//

test "pick-files asks for an open dialog with the title and replies with the paths" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createPickersCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"pick-files\",\"data\":{\"title\":\"Pick some files\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true,\"data\":[\"kind0\",\"Pick some files\",\"-\"]}");
}
test "pick-files with no title uses a default one" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createPickersCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"pick-files\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "[\"kind0\",\"Select Files\",\"-\"]");
}
test "pick-folder asks for a folder dialog with the title from the options and replies with one path" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createPickersCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"pick-folder\",\"data\":{\"title\":\"Pick a folder\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":true,\"data\":\"kind2\"}");
}
test "pick-folder with no options uses a default title" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createPickersCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"pick-folder\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":true,\"data\":\"kind2\"}");
}
test "pick-file is a save dialog with the suggested name and replies with one path" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createPickersCore(&native_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":3,\"name\":\"pick-file\",\"data\":{\"name\":\"photo.jpg\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":3,\"ok\":true,\"data\":\"kind1\"}");
}
test "a cancelled dialog is a reply of null" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(2, 2), template.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.setResult(std.testing.io, std.testing.allocator, "pick-paths", true, "[]");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":4,\"name\":\"pick-files\",\"data\":{\"title\":\"T\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":4,\"ok\":true,\"data\":null}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":5,\"name\":\"pick-folder\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":5,\"ok\":true,\"data\":null}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":6,\"name\":\"pick-file\",\"data\":{\"name\":\"x\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":6,\"ok\":true,\"data\":null}");
}
test "a native app with no dialog callback gives an error reply naming what is missing" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(2, 2);
    config.has_pick_paths = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, template.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":7,\"name\":\"pick-folder\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":7,\"ok\":false,\"error\":\"NativeCallMissing\"}");
}
//
// The task observers.
//

test "the observers the test app gives the core tell the UI of each task that ended and each event it sent" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try createCore(&native_app);
    try addTask(&native_app, "s1", "hello-short", "src", "null");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"task-ended\",\"taskId\":\"s1\"}}");
    // Stopping the core waits for the workers, so every observer call has been made before the events are counted.
    native_app.stop(std.testing.io, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"task-ended\",\"taskId\":\"s1\"}}"));
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"task-event-sent\",\"taskId\":\"s1\"}}"));
}
//
// The desktop menu.
//

test "the menu has the .ui items the UI handles and the zig-event item; toggle-devtools and quit are standard items" {
    for ([_][]const u8{ "start-short", "start-long", "start-many", "cancel-long", "about" }) |name| {
        const target = template.app.menu_targets.get(name) orelse return error.MenuItemMissing;
        try std.testing.expect(target == .ui);
    }
    const zig_event = template.app.menu_targets.get("zig-event") orelse return error.MenuItemMissing;
    try std.testing.expect(zig_event == .zig);
    try std.testing.expectEqual(@as(usize, 6), template.app.menu_targets.keys().len);
    for ([_][]const u8{ "toggle-devtools", "quit" }) |action| {
        try std.testing.expect(template.app.menu_targets.get(action) == null);
        const wanted = try std.fmt.allocPrint(std.testing.allocator, "\"action\":\"{s}\"", .{action});
        defer std.testing.allocator.free(wanted);
        try std.testing.expect(std.mem.indexOf(u8, template.app.menu_json, wanted) != null);
    }
}
test "the zig-event item's function sends the UI the app event menu-zig-event" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), template.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"zig-event\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"menu-zig-event\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true,\"data\":{}}");
}
//
// The query of the frontend's address.
//

test "the test app's UI query says the test mode switch and nothing else" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), template.app);
    const without_switch = try native_app.uiQuery(std.testing.allocator);
    defer std.testing.allocator.free(without_switch);
    native_app.stop(std.testing.io, std.testing.allocator);
    try std.testing.expectEqualStrings("", without_switch);
    // The switch is read from the configuration. It also starts the test control connection, which this test does not use.
    var config = native_app.config(1, 1);
    config.test_mode = true;
    try native_app.start(std.testing.io, std.testing.allocator, config, template.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const with_switch = try native_app.uiQuery(std.testing.allocator);
    defer std.testing.allocator.free(with_switch);
    try std.testing.expectEqualStrings("testMode=1", with_switch);
}
test "the test app core gives the UI an empty query outside test mode" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), template.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const query = try native_app.uiQuery(std.testing.allocator);
    defer std.testing.allocator.free(query);
    try std.testing.expectEqualStrings("", query);
}
//
// The media server.
//

test "parseRange reads a closed range" {
    const range = (try media_server.parseRange("bytes=10-19", 100)).?;
    try std.testing.expectEqual(@as(usize, 10), range.start);
    try std.testing.expectEqual(@as(usize, 19), range.end);
}
test "parseRange reads an open ended range up to the last byte" {
    const range = (try media_server.parseRange("bytes=90-", 100)).?;
    try std.testing.expectEqual(@as(usize, 90), range.start);
    try std.testing.expectEqual(@as(usize, 99), range.end);
}
test "parseRange reads a suffix range as the last bytes" {
    const range = (try media_server.parseRange("bytes=-10", 100)).?;
    try std.testing.expectEqual(@as(usize, 90), range.start);
    try std.testing.expectEqual(@as(usize, 99), range.end);
}
test "parseRange cuts an end past the file to the last byte" {
    const range = (try media_server.parseRange("bytes=50-500", 100)).?;
    try std.testing.expectEqual(@as(usize, 99), range.end);
}
test "parseRange refuses a start past the end of the file" {
    try std.testing.expectError(error.Unsatisfiable, media_server.parseRange("bytes=100-", 100));
}
test "parseRange returns null when the header does not ask for bytes" {
    try std.testing.expectEqual(@as(?media_server.ByteRange, null), try media_server.parseRange("items=1-2", 100));
}
test "findAsset finds the image and the video and ignores a query" {
    try std.testing.expect(media_server.findAsset("/example.png") != null);
    try std.testing.expect(media_server.findAsset("/example.mp4?x=1") != null);
    try std.testing.expect(media_server.findAsset("/missing.png") == null);
}
test "the media server serves the image whole, the video by range, and stops when its source is cancelled" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(2, 2), template.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const port = try startServer(&native_app);

    const image = try fetch(std.testing.allocator, port, "GET /example.png HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    defer std.testing.allocator.free(image);
    try std.testing.expect(std.mem.startsWith(u8, image, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, image, "Content-Type: image/png") != null);
    try std.testing.expect(std.mem.indexOf(u8, image, "Access-Control-Allow-Origin: *") != null);
    try std.testing.expect(std.mem.indexOf(u8, image, "\x89PNG") != null);

    const video = try fetch(std.testing.allocator, port, "GET /example.mp4 HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-99\r\n\r\n");
    defer std.testing.allocator.free(video);
    try std.testing.expect(std.mem.startsWith(u8, video, "HTTP/1.1 206 Partial Content\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, video, "Content-Range: bytes 0-99/") != null);
    try std.testing.expect(std.mem.indexOf(u8, video, "Content-Length: 100\r\n") != null);

    const missing = try fetch(std.testing.allocator, port, "GET /nothing HTTP/1.1\r\n\r\n");
    defer std.testing.allocator.free(missing);
    try std.testing.expect(std.mem.startsWith(u8, missing, "HTTP/1.1 404 Not Found\r\n"));

    const beyond = try fetch(std.testing.allocator, port, "GET /example.png HTTP/1.1\r\nRange: bytes=99999999-\r\n\r\n");
    defer std.testing.allocator.free(beyond);
    try std.testing.expect(std.mem.startsWith(u8, beyond, "HTTP/1.1 416 Range Not Satisfiable\r\n"));

    // A client that connects and sends nothing, as a browser does, must not keep the server from stopping.
    var idle_threaded: std.Io.Threaded = .init_single_threaded;
    const idle = try (try std.Io.net.IpAddress.parseIp4("127.0.0.1", port)).connect(idle_threaded.io(), .{ .mode = .stream });
    defer idle.close(idle_threaded.io());

    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"cancel-tasks\",\"data\":\"media\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "task-completed");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"errorMessage\":\"Cancelled\"");
}
