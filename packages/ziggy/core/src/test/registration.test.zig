const std = @import("std");
const ziggy = @import("ziggy");
const helpers = @import("helpers.zig");

//
// Fails unless the last message the fake native app recorded is the expected text.
//
fn expectLastMessage(native_app: *helpers.FakeNativeApp, expected: []const u8) !void {
    const last = try native_app.messageAt(std.testing.io, std.testing.allocator, native_app.count(std.testing.io, std.testing.allocator) - 1);
    defer std.testing.allocator.free(last);
    try std.testing.expectEqualStrings(expected, last);
}

//
// The data of the messages declared in these tests.
//
const LateRequest = struct {
    // A word the response repeats.
    word: []const u8,
};

//
// The response of the messages declared in these tests.
//
const LateResponse = struct {
    // Which handler ran.
    from: []const u8,
    // The payload's word.
    word: []const u8,
};

//
// A handler the app of these tests declares.
//
fn lateHandler(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, payload: LateRequest) !LateResponse {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    return .{
        .from = "late",
        .word = payload.word,
    };
}

//
// Sends a system message of the name, with no data, and gives whether the main thread has a system message of that name: any response
// but UnknownSystemMessage.
//
fn systemHas(native_app: *helpers.FakeNativeApp, name: []const u8) !bool {
    var buffer: [256]u8 = undefined;
    try native_app.send(std.testing.io, std.testing.allocator, try std.fmt.bufPrint(&buffer, "{{\"kind\":\"system\",\"id\":\"system-has\",\"name\":\"{s}\",\"data\":null}}", .{name}));
    const index = native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"id\":\"system-has\"") orelse {
        return error.SystemHasNoResponse;
    };
    const response = try native_app.messageAt(std.testing.io, std.testing.allocator, index);
    defer std.testing.allocator.free(response);
    native_app.removeContaining(std.testing.io, std.testing.allocator, "\"id\":\"system-has\"");
    return std.mem.indexOf(u8, response, "UnknownSystemMessage") == null;
}

//
// A task the app of these tests declares.
//
fn lateTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, payload: std.json.Value) ![]const u8 {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = payload;
    return "late task done";
}

//
// The app of these tests: it declares the message "late", an app message under the name of the system message get-platform, and the
// task type "late-task".
//
const declared_app = ziggy.core.App(.{
    .messages = .{
        .late = lateHandler,
        .@"get-platform" = lateHandler,
    },
    .tasks = .{
        .@"late-task" = lateTask,
    },
    .menu = &.{},
    .ui_files = &[_]ziggy.ui_files.UiFile{},
});

test "an app message the app declares is handled, and a name it does not declare is UnknownMessageName" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), declared_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"undeclared\",\"data\":{\"word\":\"hi\"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":false,\"error\":\"UnknownMessageName\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"late\",\"data\":{\"word\":\"hi\"}}");
    try expectLastMessage(&native_app, "{\"id\":2,\"ok\":true,\"data\":{\"from\":\"late\",\"word\":\"hi\"}}");
}

test "an app message declared under a system message's name is an app message, and the system message is still Ziggy's" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), declared_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"get-platform\",\"data\":{\"word\":\"app\"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{\"from\":\"late\",\"word\":\"app\"}}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"get-platform\",\"data\":null}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":true,\"data\":{\"platformKind\":");
    try std.testing.expect(!try systemHas(&native_app, "late"));
}

test "a system message is never handled as an app message, and an app message never as a system message" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), declared_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"late\",\"data\":{\"word\":\"hi\"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":false,\"error\":\"UnknownSystemMessage\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"cancel-tasks\",\"data\":\"nothing\"}");
    try expectLastMessage(&native_app, "{\"id\":2,\"ok\":false,\"error\":\"UnknownMessageName\"}");
}

test "a task type the app declares can be queued, and one it does not declare fails as UnknownTaskType" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), declared_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"before\",\"taskType\":\"undeclared-task\",\"source\":\"s\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"taskId\":\"before\",\"result\":{\"taskId\":\"before\",\"status\":\"failed\",\"error\":{\"message\":\"UnknownTaskType\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"after\",\"taskType\":\"late-task\",\"source\":\"s\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"taskId\":\"after\",\"result\":{\"taskId\":\"after\",\"status\":\"succeeded\",\"outputs\":\"late task done\"");
}

test "every system message of Ziggy's parts is handled, the test hook ones too in a test hooks build" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), declared_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    for ([_][]const u8{ "add-task", "cancel-tasks", "get-platform", "menu-action", "get-dropped-paths" }) |name| {
        try std.testing.expect(try systemHas(&native_app, name));
    }
    // The unit tests run with the test hooks built in.
    try std.testing.expect(try systemHas(&native_app, "test-result"));
    try std.testing.expect(try systemHas(&native_app, "test-ui-ready"));
}
