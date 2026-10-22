const std = @import("std");
const ziggy = @import("ziggy");
const template = @import("ziggy-test-app-backend");

const FakeShell = ziggy.fake_shell.FakeShell;

fn createCore(shell: *FakeShell, data_dir: [*:0]const u8) !*ziggy.core.Core {
    var config = shell.config(3, 4);
    config.data_dir = data_dir;
    return try ziggy.core.Core.create(std.testing.allocator, config, template.app);
}

fn addTask(core: *ziggy.core.Core, id: []const u8, task_type: []const u8, data: []const u8) !void {
    const message = try ziggy.json.stringify(std.testing.allocator, .{
        .kind = "system",
        .name = "add-task",
        .data = .{
            .taskId = id,
            .taskType = task_type,
            .source = "src",
            .data = ziggy.json.Raw{ .text = data },
            .priority = "background",
        },
    });
    defer std.testing.allocator.free(message);
    core.postMessage(message);
}

fn indexOfMessage(shell: *FakeShell, text: []const u8) !usize {
    try shell.expectMessageContaining(text);
    return shell.indexOfContaining(text).?;
}

test "ping replies with the Zig version, the platform and an echo of the payload" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"ping\",\"data\":{\"hello\":\"world\"}}");
    const reply = try shell.messageAt(std.testing.allocator, 0);
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
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
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
    core.postMessage(message);
    const reply = try shell.messageAt(std.testing.allocator, 0);
    defer std.testing.allocator.free(reply);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "\"length\":{d},\"crc32\":{d}", .{ payload.len, std.hash.Crc32.hash(payload) });
    defer std.testing.allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, reply, expected) != null);
}

test "payload-stats counts the bytes of text with non-ASCII characters" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"payload-stats\",\"data\":{\"text\":\"é世界😀\"}}");
    const reply = try shell.messageAt(std.testing.allocator, 0);
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"length\":12,") != null);
}

test "payload-stats without text is an error reply" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"payload-stats\"}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"text\\\" is missing\"}");
}

test "file-roundtrip writes a file in the data directory and reads it back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const data_dir = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, data_dir.ptr);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"file-roundtrip\",\"data\":{\"text\":\"kept \\u00e9\"}}");
    const reply = try shell.messageAt(std.testing.allocator, 0);
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"text\":\"kept é\"") != null);
    var buffer: [64]u8 = undefined;
    const written = try tmp.dir.readFile(core.io(), "ziggy-test-app-roundtrip.txt", &buffer);
    try std.testing.expectEqualStrings("kept é", written);
}

test "file-roundtrip reports a missing data directory as an error" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/this/directory/does/not/exist");
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"file-roundtrip\",\"data\":{\"text\":\"x\"}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"FileNotFound\"}");
}

test "the fail message replies with an error" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"fail\"}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"ExampleFailure\"}");
}

test "hello-short sends an output event and a job-progress event then completes" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "t1", "hello-short", "{\"job\":{\"id\":\"job-1\",\"name\":\"Short job\",\"cancelSource\":\"src\"}}");
    const output = try indexOfMessage(&shell, "\"source\":\"src\",\"data\":{\"type\":\"output\",\"text\":\"hello from a short task\"}");
    const progress = try indexOfMessage(&shell, "\"source\":\"src\",\"data\":{\"type\":\"job-progress\",\"job\":{\"id\":\"job-1\",\"name\":\"Short job\",\"cancelSource\":\"src\"},\"startedAt\":");
    const completed = try indexOfMessage(&shell, "\"status\":\"succeeded\",\"outputs\":\"short task done\"");
    try std.testing.expect(output < progress);
    try std.testing.expect(progress < completed);
    try shell.expectMessageContaining("\"progressMessage\":\"short task working\"}");
}

test "a job-progress event leaves out the cancel source when the job has none" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "t1", "hello-short", "{\"job\":{\"id\":\"job-1\",\"name\":\"Short job\"}}");
    try shell.expectMessageContaining("\"job\":{\"id\":\"job-1\",\"name\":\"Short job\"},\"startedAt\"");
}

test "a task with no job sends no job-progress event" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "t1", "hello-short", "{}");
    try shell.expectMessageContaining("\"status\":\"succeeded\"");
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("job-progress"));
}

test "hello-long sends output and progress at every step, starts its children and waits for them" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "long", "hello-long", "{\"durationMs\":200,\"stepMs\":50,\"children\":3,\"job\":{\"id\":\"job-1\",\"name\":\"Long job\",\"cancelSource\":\"src\"}}");
    try shell.expectMessageContaining("\"result\":{\"taskId\":\"long\",\"status\":\"succeeded\",\"outputs\":{\"steps\":4,\"children\":3}");
    try std.testing.expectEqual(@as(usize, 4), shell.countContaining("\"taskId\":\"long\",\"source\":\"src\",\"data\":{\"type\":\"output\",\"text\":\"long task step"));
    try std.testing.expectEqual(@as(usize, 3), shell.countContaining("child long.c"));
    try std.testing.expectEqual(@as(usize, 3), shell.countContaining("\"status\":\"succeeded\",\"outputs\":{\"index\":"));
    // The children report under the parent's job id.
    try std.testing.expect(shell.countContaining("\"taskId\":\"long.c0\",\"source\":\"src\",\"data\":{\"type\":\"job-progress\",\"job\":{\"id\":\"job-1\"") == 1);
    // The parent's completion is the last thing that happens.
    try std.testing.expect(shell.indexOfContaining("\"result\":{\"taskId\":\"long\",\"status\"").? > shell.indexOfContaining("\"result\":{\"taskId\":\"long.c2\",\"status\"").?);
}

test "hello-long with no children and more children than steps both complete" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "a", "hello-long", "{\"durationMs\":50,\"stepMs\":50,\"children\":0}");
    try shell.expectMessageContaining("\"result\":{\"taskId\":\"a\",\"status\":\"succeeded\",\"outputs\":{\"steps\":1,\"children\":0}");
    try addTask(core, "b", "hello-long", "{\"durationMs\":50,\"stepMs\":50,\"children\":5}");
    try shell.expectMessageContaining("\"result\":{\"taskId\":\"b\",\"status\":\"succeeded\",\"outputs\":{\"steps\":1,\"children\":5}");
}

test "cancelling hello-long stops it early and its children are cancelled" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "long", "hello-long", "{\"durationMs\":60000,\"stepMs\":20,\"children\":2}");
    try shell.expectMessageContaining("long task step 3");
    core.postMessage("{\"kind\":\"system\",\"name\":\"cancel-tasks\",\"data\":\"src\"}");
    try shell.expectMessageContaining("\"status\":\"failed\",\"error\":{\"message\":\"Cancelled\"},\"errorMessage\":\"Cancelled\"");
    try std.testing.expect(shell.countContaining("\"taskId\":\"long\",\"source\":\"src\",\"data\":{\"type\":\"output\",\"text\":\"long task step") < 100);
}

test "hello-fail completes as failed" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "t1", "hello-fail", "null");
    try shell.expectMessageContaining("\"status\":\"failed\",\"error\":{\"message\":\"HelloFailure\"},\"errorMessage\":\"HelloFailure\"");
}

test "os-version returns what the shell's native host callback answers" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "t1", "os-version", "null");
    try shell.expectMessageContaining("\"status\":\"succeeded\",\"outputs\":\"Test OS 1.0\"");
}

test "os-version fails clearly when the shell provides no native host callback" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(1, 1);
    config.os_version = null;
    const core = try ziggy.core.Core.create(std.testing.allocator, config, template.app);
    defer core.destroy();
    try addTask(core, "t1", "os-version", "null");
    try shell.expectMessageContaining("\"status\":\"failed\",\"error\":{\"message\":\"HostCallbackMissing\"},\"errorMessage\":\"HostCallbackMissing\"");
}

test "the keep-alive background task counts in a file in the data directory and asks the shell to keep the app running, and the normal one does not" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(data_dir);
    const data_dir_z = try std.testing.allocator.dupeZ(u8, data_dir);
    defer std.testing.allocator.free(data_dir_z);

    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, data_dir_z.ptr);
    defer core.destroy();
    try addTask(core, "bk", "background-keep-alive", "{\"file\":\"keep.txt\",\"durationMs\":300}");
    try addTask(core, "bn", "background-normal", "{\"file\":\"normal.txt\",\"durationMs\":300}");
    _ = try indexOfMessage(&shell, "task-completed\",\"data\":{\"taskId\":\"bk\"");
    _ = try indexOfMessage(&shell, "task-completed\",\"data\":{\"taskId\":\"bn\"");

    const kept = try tmp.dir.readFileAlloc(std.testing.io, "keep.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(kept);
    try std.testing.expect(try std.fmt.parseInt(u32, std.mem.trim(u8, kept, "\n"), 10) >= 2);
    const normal = try tmp.dir.readFileAlloc(std.testing.io, "normal.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(normal);
    try std.testing.expect(try std.fmt.parseInt(u32, std.mem.trim(u8, normal, "\n"), 10) >= 2);

    shell.mutex.lockUncancelable(shell.threaded.io());
    defer shell.mutex.unlock(shell.threaded.io());
    try std.testing.expectEqualSlices(bool, &[_]bool{ true, false }, shell.keep_alive_calls.items);
}

test "file-roundtrip without text is an error reply" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"file-roundtrip\"}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"text\\\" is missing\"}");
}

fn refusingOsVersion(user_data: ?*anyopaque, buffer: [*]u8, capacity: usize) callconv(.c) isize {
    _ = user_data;
    _ = buffer;
    _ = capacity;
    return -1;
}

test "os-version fails clearly when the shell cannot answer" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(1, 1);
    config.os_version = refusingOsVersion;
    const core = try ziggy.core.Core.create(std.testing.allocator, config, template.app);
    defer core.destroy();
    try addTask(core, "t1", "os-version", "null");
    try shell.expectMessageContaining("\"status\":\"failed\",\"error\":{\"message\":\"HostCallbackFailed\"},\"errorMessage\":\"HostCallbackFailed\"");
}

test "a background task without a file to count in fails with MissingFile" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "bm", "background-normal", "{\"durationMs\":300}");
    try shell.expectMessageContaining("\"errorMessage\":\"MissingFile\"");
}

test "a message of a name the test app does not know is an UnknownMessageName error" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"no-such-name\"}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"UnknownMessageName\"}");
}

test "a message with no name, or an empty one, is refused with MissingMessageName" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"data\":{\"text\":\"x\"}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"MissingMessageName\"}");
    core.postMessage("{\"kind\":\"app\",\"id\":2,\"name\":\"\",\"data\":\"a string, not an object\"}");
    try shell.expectMessageContaining("{\"id\":2,\"ok\":false,\"error\":\"MissingMessageName\"}");
}
