const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");
const helpers = @import("helpers.zig");

fn lastMessage(shell: *helpers.FakeShell) ![]u8 {
    return try shell.messageAt(std.testing.allocator, shell.count() - 1);
}

//
// Fails unless the last message the shell recorded is the expected text.
//
fn expectLastMessage(shell: *helpers.FakeShell, expected: []const u8) !void {
    const last = try lastMessage(shell);
    defer std.testing.allocator.free(last);
    try std.testing.expectEqualStrings(expected, last);
}

test "a message with an id reaches the app's message handler and its response comes back with the same id" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":7,\"name\":\"echo\",\"data\":{\"a\":1}}");
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":7,\"ok\":true,\"data\":{\"a\":1}}", reply);
}

test "a string id is echoed as a string" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":\"abc\",\"name\":\"echo\",\"data\":null}");
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":\"abc\",\"ok\":true,\"data\":null}", reply);
}

test "a system message name Ziggy does not know gets UnknownSystemMessage" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":1,\"name\":\"nope\",\"data\":null}");
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":1,\"ok\":false,\"error\":\"UnknownSystemMessage\"}", reply);
}

test "test-result and test-ui-ready are error replies when the core is not in test mode" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":1,\"name\":\"test-result\",\"data\":{\"requestId\":1,\"result\":null}}");
    const first = try lastMessage(&shell);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{\"id\":1,\"ok\":false,\"error\":\"TestControlNotRunning\"}", first);
    core.postMessage("{\"kind\":\"system\",\"id\":2,\"name\":\"test-ui-ready\",\"data\":null}");
    const second = try lastMessage(&shell);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("{\"id\":2,\"ok\":false,\"error\":\"TestControlNotRunning\"}", second);
}

test "malformed JSON is reported as a core-error event and the core keeps working" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{not json");
    core.postMessage("[1,2,3]");
    try std.testing.expectEqual(@as(usize, 2), shell.countContaining("\"kind\":\"system\",\"name\":\"core-error\""));
    try std.testing.expectEqual(@as(usize, 2), shell.countContaining("InvalidMessage"));
    core.postMessage("{\"kind\":\"app\",\"id\":2,\"name\":\"echo\",\"data\":1}");
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":2,\"ok\":true,\"data\":1}", reply);
}

test "the message's name reaches the app's message handler unchanged" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":7,\"name\":\"name\",\"data\":null}");
    try expectLastMessage(&shell, "{\"id\":7,\"ok\":true,\"data\":\"name\"}");
}

test "a message with no name, an empty name or a name that is not a string is refused with MissingMessageName before the handler runs" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var recording_app = helpers.app;
    recording_app.messages = recording.messages;
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), recording_app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"data\":null}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":false,\"error\":\"MissingMessageName\"}");
    core.postMessage("{\"kind\":\"app\",\"id\":2,\"name\":\"\",\"data\":null}");
    try expectLastMessage(&shell, "{\"id\":2,\"ok\":false,\"error\":\"MissingMessageName\"}");
    core.postMessage("{\"kind\":\"app\",\"id\":3,\"name\":7,\"data\":null}");
    try expectLastMessage(&shell, "{\"id\":3,\"ok\":false,\"error\":\"MissingMessageName\"}");
    // A message sent with send has no message response to carry the refusal, so it is a core-error event.
    core.postMessage("{\"kind\":\"app\",\"data\":null}");
    try expectLastMessage(&shell, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"MissingMessageName\"}}");
    core.postMessage("{\"kind\":\"app\",\"name\":\"\"}");
    try expectLastMessage(&shell, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"MissingMessageName\"}}");
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("the app's message handler was called"));
}

test "a handler that fails gets an error response when the message has an id and a core-error event when not" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":3,\"name\":\"nope\",\"data\":1}");
    try shell.expectMessageContaining("{\"id\":3,\"ok\":false,\"error\":\"UnknownMessageName\"}");
    core.postMessage("{\"kind\":\"app\",\"name\":\"fail\"}");
    try shell.expectMessageContaining("{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"HandlerFailed\"}}");
}

test "a system message whose name is not a string is an invalid message" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":3,\"name\":7,\"data\":null}");
    try expectLastMessage(&shell, "{\"id\":3,\"ok\":false,\"error\":\"InvalidMessage\"}");
}

test "a handler that returns none with an id gets an empty successful response, and without an id gets nothing" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"name\":\"none\"}");
    try std.testing.expectEqual(@as(usize, 0), shell.count());
    core.postMessage("{\"kind\":\"app\",\"id\":9,\"name\":\"none\"}");
    try expectLastMessage(&shell, "{\"id\":9,\"ok\":true,\"data\":null}");
}

test "core.sendEvent delivers the data as an app event" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try core.sendEvent(arena_state.allocator(), "{\"type\":\"saved\",\"count\":2}");
    try expectLastMessage(&shell, "{\"kind\":\"app\",\"data\":{\"type\":\"saved\",\"count\":2}}");
}

//
// The handler of every message of the recording app: it records that it was called by delivering a line the test counts.
//
fn recordAppMessage(core: *ziggy.core.Core, arena: std.mem.Allocator, message: ziggy.core.Message) anyerror!ziggy.core.MessageResult {
    _ = message;
    core.deliver("{\"data\":\"the app's message handler was called\"}");
    return .{
        .response = try arena.dupe(u8, "null"),
    };
}

//
// An app whose messages carry the names of every system message, and of two of its own, each handled by recordAppMessage. A test
// takes its table of messages into a copy of the tests' app, to see whether a message reaches the app.
//
const recording = ziggy.core.App(.{
    .messages = .{
        .@"get-platform" = recordAppMessage,
        .@"add-task" = recordAppMessage,
        .@"cancel-tasks" = recordAppMessage,
        .@"menu-action" = recordAppMessage,
        .@"get-dropped-paths" = recordAppMessage,
        .@"test-result" = recordAppMessage,
        .@"test-ui-ready" = recordAppMessage,
        .anything = recordAppMessage,
        .echo = recordAppMessage,
    },
    .tasks = .{},
    .menu = &.{},
    .ui_files = &[_]ziggy.ui_files.UiFile{},
});

test "system messages are handled by Ziggy and never reach the app, even when the app has a message of the same name" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var recording_app = helpers.app;
    recording_app.messages = recording.messages;
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), recording_app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":1,\"name\":\"get-platform\",\"data\":null}");
    core.postMessage("{\"kind\":\"system\",\"id\":2,\"name\":\"add-task\",\"data\":{\"taskId\":\"t1\",\"taskType\":\"quick\",\"source\":\"own\",\"data\":null}}");
    core.postMessage("{\"kind\":\"system\",\"id\":3,\"name\":\"cancel-tasks\",\"data\":\"own\"}");
    core.postMessage("{\"kind\":\"system\",\"id\":4,\"name\":\"menu-action\",\"data\":{\"action\":\"about\"}}");
    core.postMessage("{\"kind\":\"system\",\"id\":5,\"name\":\"get-dropped-paths\",\"data\":null}");
    var id: usize = 1;
    while (id <= 5) : (id += 1) {
        var buffer: [32]u8 = undefined;
        try shell.expectMessageContaining(try std.fmt.bufPrint(&buffer, "{{\"id\":{d},\"ok\":true,", .{id}));
    }
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("the app's message handler was called"));
    // The same handler is called for a message of the app's own, so the count above would have seen it.
    core.postMessage("{\"kind\":\"app\",\"id\":6,\"name\":\"anything\",\"data\":null}");
    try std.testing.expectEqual(@as(usize, 1), shell.countContaining("the app's message handler was called"));
}

test "an app message reaches the app's handler and never a system handler, even with a system message's name" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var recording_app = helpers.app;
    recording_app.messages = recording.messages;
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), recording_app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"get-platform\",\"data\":null}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":true,\"data\":null}");
    core.postMessage("{\"kind\":\"app\",\"id\":2,\"name\":\"menu-action\",\"data\":{\"action\":\"about\"}}");
    try expectLastMessage(&shell, "{\"id\":2,\"ok\":true,\"data\":null}");
    try std.testing.expectEqual(@as(usize, 2), shell.countContaining("the app's message handler was called"));
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("platformKind"));
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("\"name\":\"menu-action\""));
}

test "a message with no kind, or a kind that is neither app nor system, is refused as InvalidMessage with a core-error event" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var recording_app = helpers.app;
    recording_app.messages = recording.messages;
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), recording_app);
    defer core.destroy();
    const refused = [_][]const u8{
        "{\"id\":1,\"name\":\"echo\",\"data\":null}",
        "{\"kind\":\"other\",\"id\":2,\"name\":\"echo\",\"data\":null}",
        "{\"kind\":7,\"id\":3,\"name\":\"get-platform\",\"data\":null}",
        "{\"kind\":\"App\",\"name\":\"echo\"}",
    };
    for (refused) |message| {
        core.postMessage(message);
        try expectLastMessage(&shell, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"InvalidMessage\"}}");
    }
    try std.testing.expectEqual(refused.len, shell.count());
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("the app's message handler was called"));
}

test "a message without an id gets no reply" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"name\":\"echo\",\"data\":1}");
    try std.testing.expectEqual(@as(usize, 0), shell.count());
}

test "a handler that fails becomes an error reply" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":4,\"name\":\"fail\"}");
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":4,\"ok\":false,\"error\":\"HandlerFailed\"}", reply);
}

test "get-platform reports the platform kind" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":5,\"name\":\"get-platform\",\"data\":null}");
    // Android and iOS are the mobile platforms, and every other platform is desktop. The test runs on both, so it names the
    // kind each is expected to report.
    const expected = if (builtin.os.tag == .ios or builtin.abi.isAndroid())
        "\"platformKind\":\"mobile\""
    else
        "\"platformKind\":\"desktop\"";
    try shell.expectMessageContaining(expected);
}

test "text with quotes, newlines and non-ASCII characters round trips unchanged" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":6,\"name\":\"echo\",\"data\":{\"text\":\"say \\\"hi\\\"\\nline two \\u00e9 \\u4e16\\u754c \\ud83d\\ude00\"}}");
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reply, .{});
    defer parsed.deinit();
    const text = parsed.value.object.get("data").?.object.get("text").?.string;
    try std.testing.expectEqualStrings("say \"hi\"\nline two é 世界 😀", text);
}

test "a multi-megabyte payload round trips unchanged" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    const payload = try std.testing.allocator.alloc(u8, 6 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*byte, index| {
        byte.* = 'a' + @as(u8, @intCast(index % 26));
    }
    const message = try ziggy.json.stringify(std.testing.allocator, .{
        .kind = "app",
        .id = 8,
        .name = "echo",
        .data = .{
            .blob = payload,
        },
    });
    defer std.testing.allocator.free(message);
    core.postMessage(message);
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reply, .{});
    defer parsed.deinit();
    const blob = parsed.value.object.get("data").?.object.get("blob").?.string;
    try std.testing.expectEqualSlices(u8, payload, blob);
}

test "create then destroy releases everything" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 3, 2);
    core.destroy();
}

test "create without a deliver callback fails" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(1, 1);
    config.deliver = null;
    try std.testing.expectError(error.DeliverCallbackMissing, ziggy.core.Core.create(std.testing.allocator, config, helpers.app));
}

test "check url uses the configured prefix" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try std.testing.expectEqual(ziggy.types.UrlDecision.allow, core.checkUrl("file:///app/dist/index.html"));
    try std.testing.expectEqual(ziggy.types.UrlDecision.block, core.checkUrl("file:///other/index.html"));
}

test "a menu-action message naming a .ui item reaches the UI as the app event menu; no menu-action event is sent" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"about\"}}");
    const event = try shell.messageAt(std.testing.allocator, 0);
    defer std.testing.allocator.free(event);
    try std.testing.expectEqualStrings("{\"kind\":\"app\",\"data\":{\"type\":\"menu\",\"item\":\"about\"}}", event);
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":true,\"data\":{}}");
    // An item in a submenu is found too.
    core.postMessage("{\"kind\":\"system\",\"id\":2,\"name\":\"menu-action\",\"data\":{\"action\":\"nested\"}}");
    try shell.expectMessageContaining("{\"kind\":\"app\",\"data\":{\"type\":\"menu\",\"item\":\"nested\"}}");
    try expectLastMessage(&shell, "{\"id\":2,\"ok\":true,\"data\":{}}");
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("\"name\":\"menu-action\""));
}

test "a menu-action message naming a .zig item calls its function with the core; its error is the error reply" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"zig-item\"}}");
    try std.testing.expectEqual(@as(usize, 1), shell.countContaining("the menu item's function ran"));
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":true,\"data\":{}}");
    core.postMessage("{\"kind\":\"system\",\"id\":2,\"name\":\"menu-action\",\"data\":{\"action\":\"failing-item\"}}");
    try expectLastMessage(&shell, "{\"id\":2,\"ok\":false,\"error\":\"MenuItemFailed\"}");
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("\"type\":\"menu\""));
}

test "a menu-action message naming an unknown item or a standard action fails with UnknownMenuItem and runs nothing" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"nonsense\"}}");
    try expectLastMessage(&shell, "{\"id\":1,\"ok\":false,\"error\":\"UnknownMenuItem\"}");
    core.postMessage("{\"kind\":\"system\",\"id\":2,\"name\":\"menu-action\",\"data\":{\"action\":\"quit\"}}");
    try expectLastMessage(&shell, "{\"id\":2,\"ok\":false,\"error\":\"UnknownMenuItem\"}");
    try std.testing.expectEqual(@as(usize, 2), shell.count());
}

test "a menu-action message with no action is an error reply" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"action\\\" is missing\"}");
}

test "the core holds the app's menu for shells to read" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try std.testing.expectEqualStrings(ziggy.menu.menuJson(helpers.menu), core.menu_json);
    try std.testing.expect(core.menu_targets.get("zig-item") != null);
}

test "the core finds a file of the app's bundled UI by the path of a request" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try std.testing.expectEqualStrings("<html></html>", core.uiFile("/index.html").?.content);
    try std.testing.expectEqualStrings("index.html", core.uiFile("/").?.path);
    try std.testing.expect(core.uiFile("/missing.js") == null);
}

test "answerWithTask answers the message with the task's result, without blocking the dispatcher" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":11,\"name\":\"quick-request\"}");
    try shell.expectMessageContaining("{\"id\":11,\"ok\":true,\"data\":\"done\"}");
    // The reply is the only thing sent: a request's task sends no task-completed event of its own.
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("task-completed"));
}

test "a message answered by a task that fails gets an error response" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":12,\"name\":\"fail-request\"}");
    try shell.expectMessageContaining("{\"id\":12,\"ok\":false,\"error\":\"TestFailure\"}");
}

test "answerWithTask refuses a message with no id and queues nothing" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"name\":\"quick-request\"}");
    // The refusal reaches the UI before postMessage returns, as a core-error event, because there is no id to answer.
    try expectLastMessage(&shell, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"MessageHasNoId\"}}");
    try std.testing.expectEqual(@as(usize, 0), core.runner.live.items.len);
}

test "a native dialog is shown through the shell's callback with the title and kind" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 1);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":13,\"name\":\"pick-open-request\",\"data\":\"Choose files\"}");
    try shell.expectMessageContaining("{\"id\":13,\"ok\":true,\"data\":[\"kind0\",\"Choose files\",\"-\"]}");
    core.postMessage("{\"kind\":\"app\",\"id\":14,\"name\":\"pick-save-request\",\"data\":\"photo.jpg\"}");
    try shell.expectMessageContaining("{\"id\":14,\"ok\":true,\"data\":[\"kind1\",\"-\",\"photo.jpg\"]}");
}

test "a dialog with no callback from the shell is an error reply naming what is missing" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(2, 1);
    config.pick_paths = null;
    const core = try ziggy.core.Core.create(std.testing.allocator, config, helpers.app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":15,\"name\":\"pick-open-request\"}");
    try shell.expectMessageContaining("{\"id\":15,\"ok\":false,\"error\":\"HostCallbackMissing\"}");
}

test "get-dropped-paths replies with the paths of the last drop, and an empty array before any drop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dropped one.txt",
        .data = "abcd",
    });
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "dropped one.txt" });
    defer std.testing.allocator.free(path);
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 2);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":1,\"name\":\"get-dropped-paths\",\"data\":null}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":true,\"data\":[]}");
    const paths_json = try ziggy.json.stringify(std.testing.allocator, &[_][]const u8{path});
    defer std.testing.allocator.free(paths_json);
    try core.filesDropped(paths_json);
    core.postMessage("{\"kind\":\"system\",\"id\":2,\"name\":\"get-dropped-paths\",\"data\":null}");
    const expected = try ziggy.json.stringify(std.testing.allocator, .{
        .id = 2,
        .ok = true,
        .data = ziggy.json.Raw{ .text = paths_json },
    });
    defer std.testing.allocator.free(expected);
    try shell.expectMessageContaining(expected);
}

fn describeTestError(err: anyerror) ?[]const u8 {
    if (err == error.HandlerFailed) {
        return "the handler failed because the test said so";
    }
    return null;
}

test "an app's error describer gives the text of an error reply" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var described_app = helpers.app;
    described_app.describe_error = describeTestError;
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), described_app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":4,\"name\":\"fail\"}");
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":4,\"ok\":false,\"error\":\"the handler failed because the test said so\"}", reply);
}

test "an error the describer has nothing to say about is replied to by name" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var described_app = helpers.app;
    described_app.describe_error = describeTaskError;
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), described_app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":5,\"name\":\"fail\"}");
    try shell.expectMessageContaining("{\"id\":5,\"ok\":false,\"error\":\"HandlerFailed\"}");
}

fn describeTaskError(err: anyerror) ?[]const u8 {
    if (err == error.TestFailure) {
        return "the task failed because \"the test\" said so, at C:\\dir";
    }
    return null;
}

test "an app's error describer gives the text of a failed request task's error reply" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var described_app = helpers.app;
    described_app.describe_error = describeTaskError;
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), described_app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":6,\"name\":\"fail-request\"}");
    try shell.expectMessageContaining("{\"id\":6,\"ok\":false,\"error\":\"the task failed because \\\"the test\\\" said so, at C:\\\\dir\"}");
}

fn addOne(value: u32) u32 {
    return value + 1;
}

test "the core's Io can run a task concurrently" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    const io = core.io();
    var future = try io.concurrent(addOne, .{41});
    try std.testing.expectEqual(@as(u32, 42), future.await(io));
}

//
// What the observer test's app records, kept in the core's app state. The test allocator reports it as a leak when the core does
// not destroy it, which is how the test knows the state was destroyed.
//
const ObserverRecord = struct {
    // Each task end, as "id|type|source|input|status".
    ends: std.ArrayList([]u8),
    // Each task message, as "id|type|message".
    messages: std.ArrayList([]u8),
    // Guards the lists, which workers append to.
    mutex: std.Io.Mutex,
};

fn createTestState(core: *ziggy.core.Core) anyerror!*anyopaque {
    const record = try core.allocator.create(ObserverRecord);
    record.* = .{
        .ends = .empty,
        .messages = .empty,
        .mutex = .init,
    };
    return record;
}

fn stopTestState(core: *ziggy.core.Core, state: *anyopaque) void {
    _ = core;
    _ = state;
}

fn destroyTestState(core: *ziggy.core.Core, state: *anyopaque) void {
    const record: *ObserverRecord = @ptrCast(@alignCast(state));
    for (record.ends.items) |text| {
        core.allocator.free(text);
    }
    for (record.messages.items) |text| {
        core.allocator.free(text);
    }
    record.ends.deinit(core.allocator);
    record.messages.deinit(core.allocator);
    core.allocator.destroy(record);
}

fn readStateTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const record: *ObserverRecord = @ptrCast(@alignCast(context.appState().?));
    return try ziggy.json.stringify(context.arena, .{
        .ends = record.ends.items.len,
    });
}

fn recordTaskEnd(core: *ziggy.core.Core, end: ziggy.types.TaskEnd) void {
    const record: *ObserverRecord = @ptrCast(@alignCast(core.app_state.?));
    const text = std.fmt.allocPrint(core.allocator, "{s}|{s}|{s}|{s}|{s}", .{ end.task_id, end.task_type, end.source, end.input_json, @tagName(end.status) }) catch @panic("out of memory");
    record.mutex.lockUncancelable(core.io());
    defer record.mutex.unlock(core.io());
    record.ends.append(core.allocator, text) catch @panic("out of memory");
}

fn recordTaskMessage(core: *ziggy.core.Core, sent: ziggy.types.TaskSentMessage) void {
    const record: *ObserverRecord = @ptrCast(@alignCast(core.app_state.?));
    const text = std.fmt.allocPrint(core.allocator, "{s}|{s}|{s}", .{ sent.task_id, sent.task_type, sent.message_json }) catch @panic("out of memory");
    record.mutex.lockUncancelable(core.io());
    defer record.mutex.unlock(core.io());
    record.messages.append(core.allocator, text) catch @panic("out of memory");
}

test "an app observes the end of a task and the messages it sent, and keeps its own state in the core" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var observed_app = helpers.app;
    observed_app.on_task_end = recordTaskEnd;
    observed_app.on_task_message = recordTaskMessage;
    observed_app.state = .{
        .create = createTestState,
        .stop = stopTestState,
        .destroy = destroyTestState,
    };
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), observed_app);
    defer core.destroy();
    const record: *ObserverRecord = @ptrCast(@alignCast(core.app_state.?));
    core.postMessage("{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"t1\",\"taskType\":\"quick\",\"source\":\"src\",\"data\":{\"a\":1},\"priority\":\"background\"}}");
    var waited_ms: u32 = 0;
    while (waited_ms < 20_000) : (waited_ms += 2) {
        record.mutex.lockUncancelable(core.io());
        const seen = record.ends.items.len;
        record.mutex.unlock(core.io());
        if (seen > 0) {
            break;
        }
        shell.sleepMs(2);
    }
    record.mutex.lockUncancelable(core.io());
    defer record.mutex.unlock(core.io());
    try std.testing.expectEqual(@as(usize, 1), record.ends.items.len);
    try std.testing.expectEqualStrings("t1|quick|src|{\"a\":1}|succeeded", record.ends.items[0]);
    try std.testing.expectEqual(@as(usize, 1), record.messages.items.len);
    try std.testing.expectEqualStrings("t1|quick|{\"text\":\"hello\"}", record.messages.items[0]);
}

test "a task handler reaches the app's state through its context" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const state_tasks = helpers.task_handlers ++ [_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "read-state", .handler = readStateTask },
    };
    var state_app = helpers.app;
    state_app.tasks = &state_tasks;
    state_app.state = .{
        .create = createTestState,
        .stop = stopTestState,
        .destroy = destroyTestState,
    };
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), state_app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"t2\",\"taskType\":\"read-state\",\"source\":\"src\",\"data\":null,\"priority\":\"background\"}}");
    try shell.expectMessageContaining("\"outputs\":{\"ends\":");
}

//
// What the ordering test's state hooks do, in order, each a line delivered to the shell, so the test reads the order from the messages the
// shell recorded.
//
fn deliverState(core: *ziggy.core.Core, name: []const u8) void {
    const message = ziggy.json.stringify(core.allocator, .{
        .stateHook = name,
    }) catch @panic("out of memory");
    defer core.allocator.free(message);
    core.deliver(message);
}

fn createOrderedState(core: *ziggy.core.Core) anyerror!*anyopaque {
    deliverState(core, "created");
    return core;
}

fn stopOrderedState(core: *ziggy.core.Core, state: *anyopaque) void {
    _ = state;
    deliverState(core, "stopped");
}

fn destroyOrderedState(core: *ziggy.core.Core, state: *anyopaque) void {
    _ = state;
    deliverState(core, "destroyed");
}

//
// A task that runs until it is cancelled and then says it was, as the last thing it does.
//
fn sayWhenCancelledTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    try context.sendMessage(.{ .started = true });
    while (true) {
        context.checkCancelled() catch {
            // The state the test made is the core itself, which the task reads through its context as a task does.
            const core: *ziggy.core.Core = @ptrCast(@alignCast(context.appState().?));
            deliverState(core, "task-ended");
            return error.Cancelled;
        };
        try context.io().sleep(.fromMilliseconds(1), .awake);
    }
}

test "the app's state is stopped before the task runner stops and destroyed after it, so a running task never reads a state that is gone" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const ordered_tasks = helpers.task_handlers ++ [_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "say-when-cancelled", .handler = sayWhenCancelledTask },
    };
    var ordered_app = helpers.app;
    ordered_app.tasks = &ordered_tasks;
    ordered_app.state = .{
        .create = createOrderedState,
        .stop = stopOrderedState,
        .destroy = destroyOrderedState,
    };
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), ordered_app);
    // A task that is still running when the core is destroyed, and says so each time round its loop.
    core.postMessage("{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"running\",\"taskType\":\"say-when-cancelled\",\"source\":\"src\",\"data\":null,\"priority\":\"background\"}}");
    try shell.expectMessageContaining("\"started\":true");
    core.destroy();
    const created = shell.indexOfContaining("\"stateHook\":\"created\"").?;
    const stopped = shell.indexOfContaining("\"stateHook\":\"stopped\"").?;
    const destroyed = shell.indexOfContaining("\"stateHook\":\"destroyed\"").?;
    try std.testing.expect(created < stopped);
    // The task is cancelled when the task runner stops, which is after the state was stopped and before it is destroyed.
    const task_ended = shell.indexOfContaining("\"stateHook\":\"task-ended\"").?;
    try std.testing.expect(stopped < task_ended);
    try std.testing.expect(task_ended < destroyed);
}
