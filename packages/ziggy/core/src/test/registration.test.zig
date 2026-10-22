const std = @import("std");
const ziggy = @import("ziggy");
const helpers = @import("helpers.zig");

//
// Fails unless the last message the fake native app recorded is the expected text.
//
fn expectLastMessage(shell: *helpers.FakeShell, expected: []const u8) !void {
    const last = try shell.messageAt(std.testing.allocator, shell.count() - 1);
    defer std.testing.allocator.free(last);
    try std.testing.expectEqualStrings(expected, last);
}

//
// The registry of system messages, which the core holds untyped. It is a registry of the same type as the app's, so the tests reach
// it by that type.
//
fn systemRegistry(core: *ziggy.core.Core) *@TypeOf(core.app_messages) {
    return @ptrCast(@alignCast(core.system_messages));
}

//
// The data of the messages registered in these tests.
//
const LateRequest = struct {
    // A word the response repeats.
    word: []const u8,
};

//
// The response of the messages registered in these tests.
//
const LateResponse = struct {
    // Which handler answered.
    from: []const u8,
    // The request's word.
    word: []const u8,
};

//
// A handler registered while the core runs.
//
fn lateHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: LateRequest) !LateResponse {
    _ = core;
    _ = arena;
    return .{
        .from = "late",
        .word = request.word,
    };
}

//
// A system handler registered while the core runs.
//
fn lateSystemHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: LateRequest) !LateResponse {
    _ = core;
    _ = arena;
    return .{
        .from = "late system",
        .word = request.word,
    };
}

//
// A task registered while the core runs.
//
fn lateTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    return try context.arena.dupe(u8, "\"late task done\"");
}

test "an app message registered while the core runs is handled from then on" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"late\",\"data\":{\"word\":\"hi\"}}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":false,\"error\":\"UnknownMessageName\"}");
    const registering = try std.Thread.spawn(.{}, registerLate, .{core});
    registering.join();
    core.postMessage("{\"kind\":\"app\",\"id\":2,\"name\":\"late\",\"data\":{\"word\":\"hi\"}}");
    try expectLastMessage(&shell, "{\"id\":2,\"ok\":true,\"data\":{\"from\":\"late\",\"word\":\"hi\"}}");
}

//
// Registers the late message, on a thread of its own.
//
fn registerLate(core: *ziggy.core.Core) void {
    core.registerMessage("late", lateHandler) catch |err| {
        std.debug.panic("the late message could not be registered: {s}", .{@errorName(err)});
    };
}

test "registering an app message under a name registered already, by App or by registerMessage, is DuplicateMessage" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try std.testing.expectError(error.DuplicateMessage, core.registerMessage("greet", lateHandler));
    try core.registerMessage("late", lateHandler);
    try std.testing.expectError(error.DuplicateMessage, core.registerMessage("late", lateHandler));
    // The registered handlers are the ones that stay.
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"greet\",\"data\":{\"name\":\"Ada\"}}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":true,\"data\":{\"text\":\"Hello Ada\",\"times\":1}}");
}

test "an app message registered under a system message's name is an app message, and the system message is still Ziggy's" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try core.registerMessage("get-platform", lateHandler);
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"get-platform\",\"data\":{\"word\":\"app\"}}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":true,\"data\":{\"from\":\"late\",\"word\":\"app\"}}");
    core.postMessage("{\"kind\":\"system\",\"id\":2,\"name\":\"get-platform\",\"data\":null}");
    try shell.expectMessageContaining("{\"id\":2,\"ok\":true,\"data\":{\"platformKind\":");
    try std.testing.expect(systemRegistry(core).find("late") == null);
}

test "a system message registered while the core runs is handled from then on, and never as an app message" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":1,\"name\":\"late-system\",\"data\":{\"word\":\"hi\"}}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":false,\"error\":\"UnknownSystemMessage\"}");
    try systemRegistry(core).register("late-system", lateSystemHandler);
    core.postMessage("{\"kind\":\"system\",\"id\":2,\"name\":\"late-system\",\"data\":{\"word\":\"hi\"}}");
    try expectLastMessage(&shell, "{\"id\":2,\"ok\":true,\"data\":{\"from\":\"late system\",\"word\":\"hi\"}}");
    core.postMessage("{\"kind\":\"app\",\"id\":3,\"name\":\"late-system\",\"data\":{\"word\":\"hi\"}}");
    try expectLastMessage(&shell, "{\"id\":3,\"ok\":false,\"error\":\"UnknownMessageName\"}");
}

test "registering a system message under a name registered already is DuplicateMessage" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try std.testing.expectError(error.DuplicateMessage, systemRegistry(core).register("add-task", lateSystemHandler));
    core.postMessage("{\"kind\":\"system\",\"id\":1,\"name\":\"cancel-tasks\",\"data\":\"nothing\"}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":true,\"data\":{}}");
}

test "a task type registered while the core runs can be queued from then on" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"before\",\"taskType\":\"late-task\",\"source\":\"s\"}}");
    try shell.expectMessageContaining("{\"taskId\":\"before\",\"result\":{\"taskId\":\"before\",\"status\":\"failed\",\"error\":{\"message\":\"UnknownTaskType\"}");
    try core.registerTask("late-task", lateTask);
    core.postMessage("{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"after\",\"taskType\":\"late-task\",\"source\":\"s\"}}");
    try shell.expectMessageContaining("{\"taskId\":\"after\",\"result\":{\"taskId\":\"after\",\"status\":\"succeeded\",\"outputs\":\"late task done\"");
}

test "registering a task type registered already is DuplicateTaskType" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try std.testing.expectError(error.DuplicateTaskType, core.registerTask("quick", lateTask));
    try core.registerTask("late-task", .{
        .handler = lateTask,
        .kind = .keep_alive,
    });
    try std.testing.expectError(error.DuplicateTaskType, core.registerTask("late-task", lateTask));
}

test "every system message of Ziggy's parts is registered, the test hook ones too in a test hooks build" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    const registry = systemRegistry(core);
    for ([_][]const u8{ "add-task", "cancel-tasks", "get-platform", "menu-action", "get-dropped-paths" }) |name| {
        try std.testing.expect(registry.find(name) != null);
    }
    // The unit tests run with the test hooks built in.
    try std.testing.expect(registry.find("test-result") != null);
    try std.testing.expect(registry.find("test-ui-ready") != null);
}
