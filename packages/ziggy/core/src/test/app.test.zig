const std = @import("std");
const ziggy = @import("ziggy");
const helpers = @import("helpers.zig");

//
// Fails unless the last message the shell recorded is the expected text.
//
fn expectLastMessage(shell: *helpers.FakeShell, expected: []const u8) !void {
    const last = try shell.messageAt(std.testing.allocator, shell.count() - 1);
    defer std.testing.allocator.free(last);
    try std.testing.expectEqualStrings(expected, last);
}

test "a message reaches the handler for its name with its data parsed into the handler's request, and the response is the returned struct" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"greet\",\"data\":{\"name\":\"Ada\",\"times\":2,\"title\":\"Dr \"}}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":true,\"data\":{\"text\":\"Hello Dr Ada\",\"times\":2}}");
}

test "a field the request gives a default, or that is optional, may be left out, and a field the request does not have is ignored" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"greet\",\"data\":{\"name\":\"Ada\",\"colour\":\"blue\"}}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":true,\"data\":{\"text\":\"Hello Ada\",\"times\":1}}");
}

test "data with a required field missing is InvalidMessageData naming the field, and the handler does not run" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"forget\",\"data\":{\"times\":3}}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"name\\\" is missing\"}");
    // A message with no data is parsed as an empty object, so it too names the missing field.
    core.postMessage("{\"kind\":\"app\",\"id\":2,\"name\":\"forget\"}");
    try expectLastMessage(&shell, "{\"id\":2,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"name\\\" is missing\"}");
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("forgot"));
}

test "data with a field of the wrong type is InvalidMessageData naming the field, and the handler does not run" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"forget\",\"data\":{\"name\":\"Ada\",\"times\":\"many\"}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"times\\\" does not fit (");
    core.postMessage("{\"kind\":\"app\",\"id\":2,\"name\":\"forget\",\"data\":{\"name\":\"Ada\",\"times\":-1}}");
    try shell.expectMessageContaining("{\"id\":2,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"times\\\" does not fit (");
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("forgot"));
}

test "data that is not an object, for a request that is a struct, is InvalidMessageData" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"forget\",\"data\":\"Ada\"}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the data is not an object\"}");
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("forgot"));
}

test "a request that is not a struct is parsed too, and data that does not fit it is InvalidMessageData" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"count\",\"data\":[4,5,6]}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":true,\"data\":3}");
    core.postMessage("{\"kind\":\"app\",\"id\":2,\"name\":\"count\",\"data\":{\"a\":1}}");
    try expectLastMessage(&shell, "{\"id\":2,\"ok\":false,\"error\":\"InvalidMessageData: UnexpectedToken\"}");
}

test "data that does not fit a message sent with no id is a core-error event" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"name\":\"forget\",\"data\":7}");
    try expectLastMessage(&shell, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"InvalidMessageData: the data is not an object\"}}");
}

test "a handler that returns nothing answers a message with an id with null" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"forget\",\"data\":{\"name\":\"Ada\",\"times\":4}}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":true,\"data\":null}");
    try std.testing.expectEqual(@as(usize, 1), shell.countContaining("forgot Ada 4"));
}

test "a name the app has no handler for is UnknownMessageName" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"greet-everyone\",\"data\":null}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":false,\"error\":\"UnknownMessageName\"}");
    core.postMessage("{\"kind\":\"app\",\"name\":\"Greet\",\"data\":null}");
    try expectLastMessage(&shell, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"UnknownMessageName\"}}");
}

test "a handler that takes ziggy.core.Message gets the message unparsed, and can answer with a task" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"echo\",\"data\":{\"anything\":[1,\"two\"]}}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":true,\"data\":{\"anything\":[1,\"two\"]}}");
    core.postMessage("{\"kind\":\"app\",\"id\":2,\"name\":\"quick-request\"}");
    try shell.expectMessageContaining("{\"id\":2,\"ok\":true,\"data\":\"done\"}");
}

//
// A task handler for the test of App's task table.
//
fn tableTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    _ = data;
    return null;
}

test "App makes the task table from the task types, each with its handler and kind" {
    const registered = ziggy.core.App(.{
        .messages = .{},
        .tasks = .{
            .plain = tableTask,
            .@"kept-alive" = .{
                .handler = tableTask,
                .kind = .keep_alive,
            },
        },
        .menu = &.{},
        .ui_files = &[_]ziggy.ui_files.UiFile{},
    });
    try std.testing.expectEqual(@as(usize, 2), registered.tasks.len);
    try std.testing.expectEqualStrings("plain", registered.tasks[0].name);
    try std.testing.expectEqual(ziggy.task_runner.TaskKind.normal, registered.tasks[0].kind);
    try std.testing.expectEqualStrings("kept-alive", registered.tasks[1].name);
    try std.testing.expectEqual(ziggy.task_runner.TaskKind.keep_alive, registered.tasks[1].kind);
    try std.testing.expect(registered.tasks[1].handler == &tableTask);
    try std.testing.expectEqual(@as(usize, 0), registered.messages.len);
    try std.testing.expect(registered.describe_error == null);
    try std.testing.expect(registered.ui_query == null);
}

//
// What the answering app's handlers keep between a message and the test: the reply of the last message that answers later.
//
const LaterState = struct {
    // The reply the later handler kept, or null before it ran.
    reply: ?ziggy.core.Reply(helpers.GreetResponse),
};

//
// Makes the answering app's state.
//
fn createLaterState(core: *ziggy.core.Core) anyerror!*anyopaque {
    const state = try core.allocator.create(LaterState);
    state.* = .{
        .reply = null,
    };
    return state;
}

//
// Stops the answering app's state, which runs nothing by itself.
//
fn stopLaterState(core: *ziggy.core.Core, state: *anyopaque) void {
    _ = core;
    _ = state;
}

//
// Releases the answering app's state.
//
fn destroyLaterState(core: *ziggy.core.Core, state: *anyopaque) void {
    const later: *LaterState = @ptrCast(@alignCast(state));
    core.allocator.destroy(later);
}

//
// The answering app's state, from the core.
//
fn laterState(core: *ziggy.core.Core) *LaterState {
    return @ptrCast(@alignCast(core.app_state.?));
}

//
// now: answers at once through Answer.
//
fn answerNowHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: helpers.GreetRequest) !ziggy.core.Answer(helpers.GreetResponse) {
    _ = core;
    return .{
        .now = .{
            .text = try std.fmt.allocPrint(arena, "Now {s}", .{request.name}),
            .times = request.times,
        },
    };
}

//
// task: answers with the sleep task, given the request, which names the sleep after the request's name.
//
fn answerTaskHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: helpers.GreetRequest) !ziggy.core.Answer([]const u8) {
    _ = core;
    return .{
        .task = .{
            .task_type = "sleep",
            .data = try ziggy.json.stringify(arena, request),
        },
    };
}

//
// later: keeps its reply in the app's state for the test to answer, and answers later.
//
fn answerLaterHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: helpers.GreetRequest, reply: ziggy.core.Reply(helpers.GreetResponse)) !ziggy.core.Answer(helpers.GreetResponse) {
    _ = arena;
    _ = request;
    laterState(core).reply = reply;
    return .later;
}

//
// sent-and-now: answers through its reply and then again by what it returns, which is answering twice.
//
fn sentAndNowHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: helpers.GreetRequest, reply: ziggy.core.Reply(helpers.GreetResponse)) !ziggy.core.Answer(helpers.GreetResponse) {
    _ = core;
    _ = arena;
    try reply.send(.{
        .text = request.name,
        .times = 1,
    });
    return .{
        .now = .{
            .text = request.name,
            .times = 2,
        },
    };
}

//
// later-without-reply: says it answers later but has no reply to do it with.
//
fn laterWithoutReplyHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: helpers.GreetRequest) !ziggy.core.Answer(helpers.GreetResponse) {
    _ = core;
    _ = arena;
    _ = request;
    return .later;
}

//
// The app of the tests of Answer and Reply.
//
const answering_app = registered: {
    var registered = ziggy.core.App(.{
        .messages = .{
            .now = answerNowHandler,
            .task = answerTaskHandler,
            .later = answerLaterHandler,
            .@"sent-and-now" = sentAndNowHandler,
            .@"later-without-reply" = laterWithoutReplyHandler,
        },
        .tasks = .{},
        .menu = &.{},
        .ui_files = &[_]ziggy.ui_files.UiFile{},
        .state = ziggy.core.AppState{
            .create = createLaterState,
            .stop = stopLaterState,
            .destroy = destroyLaterState,
        },
    });
    registered.tasks = &helpers.task_handlers;
    break :registered registered;
};

test "a handler that returns Answer .now is answered at once with the value" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), answering_app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"now\",\"data\":{\"name\":\"Ada\",\"times\":3}}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":true,\"data\":{\"text\":\"Now Ada\",\"times\":3}}");
}

test "a handler that returns Answer .task is answered with the task's result" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), answering_app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"task\",\"data\":{\"name\":\"Ada\"}}");
    try shell.expectMessageContaining("{\"start\":\"Ada\"}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":true,\"data\":null}");
}

test "a handler that answers later is answered when its reply is sent, from another thread, and only once" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), answering_app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":\"x\",\"name\":\"later\",\"data\":{\"name\":\"Ada\"}}");
    try std.testing.expectEqual(@as(usize, 0), shell.count());
    const reply = laterState(core).reply.?;
    const sender = try std.Thread.spawn(.{}, sendLater, .{reply});
    sender.join();
    try expectLastMessage(&shell, "{\"id\":\"x\",\"ok\":true,\"data\":{\"text\":\"Later\",\"times\":5}}");
    try std.testing.expectError(error.MessageAlreadyAnswered, reply.send(.{
        .text = "again",
        .times = 6,
    }));
    try std.testing.expectError(error.MessageAlreadyAnswered, reply.fail(error.TooLate));
    try std.testing.expectEqual(@as(usize, 1), shell.count());
}

//
// Sends the later message's answer, on a thread of its own.
//
fn sendLater(reply: ziggy.core.Reply(helpers.GreetResponse)) void {
    reply.send(.{
        .text = "Later",
        .times = 5,
    }) catch |err| {
        std.debug.panic("the reply could not be sent: {s}", .{@errorName(err)});
    };
}

test "a reply that fails gives the message an error response" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), answering_app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":2,\"name\":\"later\",\"data\":{\"name\":\"Ada\"}}");
    try laterState(core).reply.?.fail(error.LaterFailure);
    try expectLastMessage(&shell, "{\"id\":2,\"ok\":false,\"error\":\"LaterFailure\"}");
}

test "answering through the reply and again by what the handler returns is reported as a core-error event, not a second answer" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), answering_app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":3,\"name\":\"sent-and-now\",\"data\":{\"name\":\"Ada\"}}");
    try std.testing.expectEqual(@as(usize, 2), shell.count());
    try expectLastMessage(&shell, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"MessageAlreadyAnswered: sent-and-now answered through its reply and again by what it returned\"}}");
}

test "a handler with no reply that returns .later is MessageNotAnswered" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), answering_app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":4,\"name\":\"later-without-reply\",\"data\":{\"name\":\"Ada\"}}");
    try expectLastMessage(&shell, "{\"id\":4,\"ok\":false,\"error\":\"MessageNotAnswered\"}");
}

test "a reply never answered is reported as a core-error event when the core is destroyed" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), answering_app);
    core.postMessage("{\"kind\":\"app\",\"id\":5,\"name\":\"later\",\"data\":{\"name\":\"Ada\"}}");
    try std.testing.expectEqual(@as(usize, 0), shell.count());
    core.destroy();
    try expectLastMessage(&shell, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"MessageNotAnswered: later\"}}");
}

test "a handler that takes ziggy.core.Message gets the raw data, the name and the id" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":9,\"name\":\"raw\",\"data\":[1,{\"a\":null}]}");
    try expectLastMessage(&shell, "{\"id\":9,\"ok\":true,\"data\":{\"name\":\"raw\",\"id\":9,\"data\":[1,{\"a\":null}]}}");
    core.postMessage("{\"kind\":\"app\",\"id\":10,\"name\":\"none\",\"data\":7}");
    try expectLastMessage(&shell, "{\"id\":10,\"ok\":true,\"data\":null}");
}
