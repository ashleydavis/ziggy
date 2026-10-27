const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");
const helpers = @import("helpers.zig");

fn lastMessage(native_app: *helpers.FakeNativeApp) ![]u8 {
    return try native_app.messageAt(std.testing.io, std.testing.allocator, native_app.count(std.testing.io, std.testing.allocator) - 1);
}

//
// Fails unless the last message the fake native app recorded is the expected text.
//
fn expectLastMessage(native_app: *helpers.FakeNativeApp, expected: []const u8) !void {
    const last = try lastMessage(native_app);
    defer std.testing.allocator.free(last);
    try std.testing.expectEqualStrings(expected, last);
}

test "a message with an id reaches the app's message handler and its response comes back with the same id" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":7,\"name\":\"echo\",\"data\":{\"a\":1}}");
    const reply = try lastMessage(&native_app);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":7,\"ok\":true,\"data\":{\"a\":1}}", reply);
}

test "a string id is echoed as a string" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":\"abc\",\"name\":\"echo\",\"data\":null}");
    const reply = try lastMessage(&native_app);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":\"abc\",\"ok\":true,\"data\":null}", reply);
}

test "a system message name Ziggy does not know gets UnknownSystemMessage" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"nope\",\"data\":null}");
    const reply = try lastMessage(&native_app);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":1,\"ok\":false,\"error\":\"UnknownSystemMessage\"}", reply);
}

test "test-result and test-ui-ready are error replies when the core is not in test mode" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"test-result\",\"data\":{\"requestId\":1,\"result\":null}}");
    const first = try lastMessage(&native_app);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{\"id\":1,\"ok\":false,\"error\":\"TestControlNotRunning\"}", first);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"test-ui-ready\",\"data\":null}");
    const second = try lastMessage(&native_app);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("{\"id\":2,\"ok\":false,\"error\":\"TestControlNotRunning\"}", second);
}

test "malformed JSON is reported as a core-error event and the core keeps working" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{not json");
    try native_app.send(std.testing.io, std.testing.allocator, "[1,2,3]");
    try std.testing.expectEqual(@as(usize, 2), native_app.countContaining(std.testing.io, std.testing.allocator, "\"kind\":\"system\",\"name\":\"core-error\""));
    try std.testing.expectEqual(@as(usize, 2), native_app.countContaining(std.testing.io, std.testing.allocator, "InvalidMessage"));
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"echo\",\"data\":1}");
    const reply = try lastMessage(&native_app);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":2,\"ok\":true,\"data\":1}", reply);
}

test "the message's name reaches the app's message handler unchanged" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":7,\"name\":\"name\",\"data\":null}");
    try expectLastMessage(&native_app, "{\"id\":7,\"ok\":true,\"data\":\"name\"}");
}

test "a message with no name, an empty name or a name that is not a string is refused with MissingMessageName before the handler runs" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var recording_app = helpers.app;
    recording_app.messages = recording.messages;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), recording_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"data\":null}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":false,\"error\":\"MissingMessageName\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"\",\"data\":null}");
    try expectLastMessage(&native_app, "{\"id\":2,\"ok\":false,\"error\":\"MissingMessageName\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":3,\"name\":7,\"data\":null}");
    try expectLastMessage(&native_app, "{\"id\":3,\"ok\":false,\"error\":\"MissingMessageName\"}");
    // A message sent with send has no message response to carry the refusal, so it is a core-error event.
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":null}");
    try expectLastMessage(&native_app, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"MissingMessageName\"}}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"name\":\"\"}");
    try expectLastMessage(&native_app, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"MissingMessageName\"}}");
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "the app's message handler was called"));
}

test "a handler that fails gets an error response when the message has an id and a core-error event when not" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":3,\"name\":\"nope\",\"data\":1}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":3,\"ok\":false,\"error\":\"UnknownMessageName\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"name\":\"fail\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"HandlerFailed\"}}");
}

test "a system message whose name is not a string is an invalid message" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":3,\"name\":7,\"data\":null}");
    try expectLastMessage(&native_app, "{\"id\":3,\"ok\":false,\"error\":\"InvalidMessage\"}");
}

test "a handler that returns none with an id gets an empty successful response, and without an id gets nothing" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"name\":\"none\"}");
    try std.testing.expectEqual(@as(usize, 0), native_app.count(std.testing.io, std.testing.allocator));
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":9,\"name\":\"none\"}");
    try expectLastMessage(&native_app, "{\"id\":9,\"ok\":true,\"data\":null}");
}

test "core.sendEvent delivers the data as an app event" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"name\":\"send-app-event\",\"data\":{\"type\":\"saved\",\"count\":2}}");
    try expectLastMessage(&native_app, "{\"kind\":\"app\",\"data\":{\"type\":\"saved\",\"count\":2}}");
}

//
// The handler of every message of the recording app: it records that it was called by sending an app event the test counts.
//
fn recordAppMessage(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, message: ziggy.core.Message) anyerror!ziggy.core.MessageResult {
    _ = timers;
    _ = message;
    try services.sendEvent(io, allocator, "\"the app's message handler was called\"");
    return .{
        .response = try allocator.dupe(u8, "null"),
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
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var recording_app = helpers.app;
    recording_app.messages = recording.messages;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), recording_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"get-platform\",\"data\":null}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"add-task\",\"data\":{\"taskId\":\"t1\",\"taskType\":\"quick\",\"source\":\"own\",\"data\":null}}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":3,\"name\":\"cancel-tasks\",\"data\":\"own\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":4,\"name\":\"menu-action\",\"data\":{\"action\":\"about\"}}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":5,\"name\":\"get-dropped-paths\",\"data\":null}");
    var id: usize = 1;
    while (id <= 5) : (id += 1) {
        var buffer: [32]u8 = undefined;
        try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, try std.fmt.bufPrint(&buffer, "{{\"id\":{d},\"ok\":true,", .{id}));
    }
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "the app's message handler was called"));
    // The same handler is called for a message of the app's own, so the count above would have seen it.
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":6,\"name\":\"anything\",\"data\":null}");
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "the app's message handler was called"));
}

test "an app message reaches the app's handler and never a system handler, even with a system message's name" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var recording_app = helpers.app;
    recording_app.messages = recording.messages;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), recording_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"get-platform\",\"data\":null}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":null}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"menu-action\",\"data\":{\"action\":\"about\"}}");
    try expectLastMessage(&native_app, "{\"id\":2,\"ok\":true,\"data\":null}");
    try std.testing.expectEqual(@as(usize, 2), native_app.countContaining(std.testing.io, std.testing.allocator, "the app's message handler was called"));
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "platformKind"));
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "\"name\":\"menu-action\""));
}

test "a message with no kind, or a kind that is neither app nor system, is refused as InvalidMessage with a core-error event" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var recording_app = helpers.app;
    recording_app.messages = recording.messages;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), recording_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const refused = [_][]const u8{
        "{\"id\":1,\"name\":\"echo\",\"data\":null}",
        "{\"kind\":\"other\",\"id\":2,\"name\":\"echo\",\"data\":null}",
        "{\"kind\":7,\"id\":3,\"name\":\"get-platform\",\"data\":null}",
        "{\"kind\":\"App\",\"name\":\"echo\"}",
    };
    for (refused) |message| {
        try native_app.send(std.testing.io, std.testing.allocator, message);
        try expectLastMessage(&native_app, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"InvalidMessage\"}}");
    }
    try std.testing.expectEqual(refused.len, native_app.count(std.testing.io, std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "the app's message handler was called"));
}

test "a message without an id gets no reply" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"name\":\"echo\",\"data\":1}");
    try std.testing.expectEqual(@as(usize, 0), native_app.count(std.testing.io, std.testing.allocator));
}

test "a handler that fails becomes an error reply" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":4,\"name\":\"fail\"}");
    const reply = try lastMessage(&native_app);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":4,\"ok\":false,\"error\":\"HandlerFailed\"}", reply);
}

test "get-platform reports the platform kind" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":5,\"name\":\"get-platform\",\"data\":null}");
    // Android and iOS are the mobile platforms, and every other platform is desktop. The test runs on both, so it names the
    // kind each is expected to report.
    const expected = if (builtin.os.tag == .ios or builtin.abi.isAndroid())
        "\"platformKind\":\"mobile\""
    else
        "\"platformKind\":\"desktop\"";
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, expected);
}

test "text with quotes, newlines and non-ASCII characters round trips unchanged" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":6,\"name\":\"echo\",\"data\":{\"text\":\"quote \\\"hi\\\"\\nline two \\u00e9 \\u4e16\\u754c \\ud83d\\ude00\"}}");
    const reply = try lastMessage(&native_app);
    defer std.testing.allocator.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reply, .{});
    defer parsed.deinit();
    const text = parsed.value.object.get("data").?.object.get("text").?.string;
    try std.testing.expectEqualStrings("quote \"hi\"\nline two é 世界 😀", text);
}

test "a multi-megabyte payload round trips unchanged" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
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
    try native_app.send(std.testing.io, std.testing.allocator, message);
    const reply = try lastMessage(&native_app);
    defer std.testing.allocator.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reply, .{});
    defer parsed.deinit();
    const blob = parsed.value.object.get("data").?.object.get("blob").?.string;
    try std.testing.expectEqualSlices(u8, payload, blob);
}

test "create then destroy releases everything" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 3, 2);
    native_app.stop(std.testing.io, std.testing.allocator);
}

test "create without a wake callback fails" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.wake = null;
    try std.testing.expectError(error.WakeCallbackMissing, native_app.start(std.testing.io, std.testing.allocator, config, helpers.app));
}

test "a menu-action message naming a .ui item reaches the UI as the app event menu; no menu-action event is sent" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"about\"}}");
    const event = try native_app.messageAt(std.testing.io, std.testing.allocator, 0);
    defer std.testing.allocator.free(event);
    try std.testing.expectEqualStrings("{\"kind\":\"app\",\"data\":{\"type\":\"menu\",\"item\":\"about\"}}", event);
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{}}");
    // An item in a submenu is found too.
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"menu-action\",\"data\":{\"action\":\"nested\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"menu\",\"item\":\"nested\"}}");
    try expectLastMessage(&native_app, "{\"id\":2,\"ok\":true,\"data\":{}}");
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "\"name\":\"menu-action\""));
}

test "a menu-action message naming a .zig item calls its function with the core; its error is the error reply" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"zig-item\"}}");
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "the menu item's function ran"));
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{}}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"menu-action\",\"data\":{\"action\":\"failing-item\"}}");
    try expectLastMessage(&native_app, "{\"id\":2,\"ok\":false,\"error\":\"MenuItemFailed\"}");
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "\"type\":\"menu\""));
}

test "a menu-action message naming an unknown item or a standard action fails with UnknownMenuItem and runs nothing" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"nonsense\"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":false,\"error\":\"UnknownMenuItem\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"menu-action\",\"data\":{\"action\":\"quit\"}}");
    try expectLastMessage(&native_app, "{\"id\":2,\"ok\":false,\"error\":\"UnknownMenuItem\"}");
    try std.testing.expectEqual(@as(usize, 2), native_app.count(std.testing.io, std.testing.allocator));
}

test "a menu-action message with no action is an error reply" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"action\\\" is missing\"}");
}

test "the app holds its menu for native apps to read" {
    try std.testing.expectEqualStrings(ziggy.menu.menuJson(helpers.menu), helpers.app.menu_json);
    try std.testing.expect(helpers.app.menu_targets.get("zig-item") != null);
}

test "a file of the app's bundled UI is found by the path of a request" {
    try std.testing.expectEqualStrings("<html></html>", ziggy.ui_files.findFile(helpers.app.ui_files, "/index.html").?.content);
    try std.testing.expectEqualStrings("index.html", ziggy.ui_files.findFile(helpers.app.ui_files, "/").?.path);
    try std.testing.expect(ziggy.ui_files.findFile(helpers.app.ui_files, "/missing.js") == null);
}

test "respondWithTask answers the message with the task's result, without blocking the dispatcher" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":11,\"name\":\"quick-request\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":11,\"ok\":true,\"data\":\"done\"}");
    // The reply is the only thing sent: a request's task sends no task-completed event of its own.
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "task-completed"));
}

test "a message answered by a task that fails gets an error response" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":12,\"name\":\"fail-request\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":12,\"ok\":false,\"error\":\"TestFailure\"}");
}

test "a message with no id whose response is to be a task's result is refused and queues nothing" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"name\":\"quick-request\"}");
    // The refusal reaches the frontend as a core-error event, because there is no id to respond to.
    try expectLastMessage(&native_app, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"MessageHasNoId\"}}");
    // The pool has one worker and runs its tasks in the order they were queued, so a quick task queued for the message would have sent
    // its event before this task ends.
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"after\",\"taskType\":\"child-result\",\"source\":\"own\",\"data\":null}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"after\",\"status\":\"succeeded\"");
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "\"text\":\"hello\""));
}

test "a native dialog is shown through the native app's callback with the title and kind" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":13,\"name\":\"pick-open-request\",\"data\":\"Choose files\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":13,\"ok\":true,\"data\":[\"kind0\",\"Choose files\",\"-\"]}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":14,\"name\":\"pick-save-request\",\"data\":\"photo.jpg\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":14,\"ok\":true,\"data\":[\"kind1\",\"-\",\"photo.jpg\"]}");
}

test "a dialog with no callback from the native app is an error reply naming what is missing" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(2, 1);
    config.has_pick_paths = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, helpers.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":15,\"name\":\"pick-open-request\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":15,\"ok\":false,\"error\":\"NativeCallMissing\"}");
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
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"get-dropped-paths\",\"data\":null}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true,\"data\":[]}");
    const paths_json = try ziggy.json.stringify(std.testing.allocator, &[_][]const u8{path});
    defer std.testing.allocator.free(paths_json);
    try native_app.filesDropped(std.testing.allocator, paths_json);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"get-dropped-paths\",\"data\":null}");
    const expected = try ziggy.json.stringify(std.testing.allocator, .{
        .id = 2,
        .ok = true,
        .data = ziggy.json.Raw{ .text = paths_json },
    });
    defer std.testing.allocator.free(expected);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, expected);
}

//
// What the native-services message gives: what the handler services report about the native app.
//
const NativeServicesResult = struct {
    // Whether the native app is a phone's.
    isPhone: bool,
    // The app's data directory.
    dataDir: []const u8,
};

//
// native-services: has the native app quit and run its focus-window action through the handler services, and gives what they report
// about the native app.
//
fn nativeServicesHandler(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, payload: struct {}) !NativeServicesResult {
    _ = timers;
    _ = payload;
    services.quit(io, allocator);
    services.menuAction(io, allocator, "focus-window");
    return .{
        .isPhone = services.isPhone(),
        .dataDir = services.dataDir(),
    };
}

//
// The app of the handler services tests: the helpers' app with native-services.
//
const native_services_app = registered: {
    var registered = ziggy.core.App(.{
        .messages = .{
            .@"native-services" = nativeServicesHandler,
        },
        .tasks = .{},
        .menu = &.{},
        .ui_files = &[_]ziggy.ui_files.UiFile{},
    });
    registered.tasks = &helpers.task_handlers;
    break :registered registered;
};

test "the handler services reach the native app's quit and menu action callbacks and report its data directory and kind" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    // The data directory is only reported, never written to, by this app.
    var config = native_app.config(1, 1);
    config.data_dir = "/tmp";
    try native_app.start(std.testing.io, std.testing.allocator, config, native_services_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"native-services\"}");
    // The fake native app gives a native call callback, as a phone's native app does.
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{\"isPhone\":true,\"dataDir\":\"/tmp\"}}");
    try std.testing.expect(native_app.quitCalled(std.testing.io, std.testing.allocator));
    const actions = try native_app.chosenActions(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(actions);
    try std.testing.expectEqualStrings("focus-window\n", actions);
}

test "the handler services report a desktop's native app, which has no native call callback, and quit and menu actions it lacks change nothing" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.has_native_call = false;
    config.has_quit = false;
    config.has_menu_action = false;
    // The data directory is only reported, never written to, by this app.
    config.data_dir = "/tmp";
    try native_app.start(std.testing.io, std.testing.allocator, config, native_services_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"native-services\"}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{\"isPhone\":false,\"dataDir\":\"/tmp\"}}");
    try std.testing.expect(!native_app.quitCalled(std.testing.io, std.testing.allocator));
    const actions = try native_app.chosenActions(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(actions);
    try std.testing.expectEqualStrings("", actions);
}

//
// native-callbacks: starts a thread of the app's own with a copy of the native app's callbacks, as an app starts a server, and waits
// for it to end.
//
fn nativeCallbacksHandler(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, payload: struct {}) !void {
    _ = timers;
    _ = io;
    _ = allocator;
    _ = payload;
    const thread = try std.Thread.spawn(.{}, callbackThread, .{services.nativeCallbacks()});
    thread.join();
}

//
// A thread of the app's own, with an Io and an allocator of its own: sends the frontend an event and makes a native call through the
// callbacks it was given, and sends the native call's result, or its absence, as a second event.
//
fn callbackThread(callbacks: ziggy.core.NativeCallbacks) void {
    var thread_allocator: ziggy.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();
    callbacks.sendEvent(io, allocator, "{\"from\":\"a thread of the app's own\"}") catch @panic("out of memory sending an event");
    const requester = callbacks.nativeCaller() orelse {
        callbacks.sendEvent(io, allocator, "{\"nativeCaller\":\"none\"}") catch @panic("out of memory sending an event");
        return;
    };
    const result = requester.call(io, allocator, "exportFile", "{\"key\":1}") catch @panic("the native call failed");
    defer allocator.free(result);
    const event = std.fmt.allocPrint(allocator, "{{\"nativeCallResult\":{s}}}", .{result}) catch @panic("out of memory");
    defer allocator.free(event);
    callbacks.sendEvent(io, allocator, event) catch @panic("out of memory sending an event");
}

//
// The app of the native callbacks tests.
//
const callbacks_app = registered: {
    var registered = ziggy.core.App(.{
        .messages = .{
            .@"native-callbacks" = nativeCallbacksHandler,
        },
        .tasks = .{},
        .menu = &.{},
        .ui_files = &[_]ziggy.ui_files.UiFile{},
    });
    registered.tasks = &helpers.task_handlers;
    break :registered registered;
};

test "a thread of the app's own sends the frontend events and makes native calls through the native callbacks it was given" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), callbacks_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"native-callbacks\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"from\":\"a thread of the app's own\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"nativeCallResult\":{\"method\":\"exportFile\",\"request\":{\"key\":1}}}}");
}

test "the native callbacks of a native app with no native call callback have no native caller" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.has_native_call = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, callbacks_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"native-callbacks\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"nativeCaller\":\"none\"}}");
}

fn describeTestError(err: anyerror) ?[]const u8 {
    if (err == error.HandlerFailed) {
        return "the handler failed because the test chose to";
    }
    return null;
}

test "an app's error describer gives the text of an error reply" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var described_app = helpers.app;
    described_app.describe_error = describeTestError;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), described_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":4,\"name\":\"fail\"}");
    const reply = try lastMessage(&native_app);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":4,\"ok\":false,\"error\":\"the handler failed because the test chose to\"}", reply);
}

test "an error the describer has no description for is replied to by name" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var described_app = helpers.app;
    described_app.describe_error = describeTaskError;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), described_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":5,\"name\":\"fail\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":5,\"ok\":false,\"error\":\"HandlerFailed\"}");
}

fn describeTaskError(err: anyerror) ?[]const u8 {
    if (err == error.TestFailure) {
        return "the task failed because \"the test\" chose to, at C:\\dir";
    }
    return null;
}

test "an app's error describer gives the text of a failed request task's error reply" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var described_app = helpers.app;
    described_app.describe_error = describeTaskError;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), described_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":6,\"name\":\"fail-request\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":6,\"ok\":false,\"error\":\"the task failed because \\\"the test\\\" chose to, at C:\\\\dir\"}");
}

//
// The observer test's observer of a task that ended: sends it as the app event `{ "observedEnd": "id|type|source|input|status" }`, so
// the test reads it from the messages the fake native app recorded.
//
fn recordTaskEnd(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, end: ziggy.types.TaskEnd) void {
    _ = timers;
    const text = std.fmt.allocPrint(allocator, "{s}|{s}|{s}|{s}|{s}", .{ end.task_id, end.task_type, end.source, end.input_json, @tagName(end.status) }) catch @panic("out of memory");
    const message = ziggy.json.stringify(allocator, .{
        .observedEnd = text,
    }) catch @panic("out of memory");
    services.sendEvent(io, allocator, message) catch @panic("out of memory");
}

//
// The observer test's observer of an event a task sent: sends it as the app event `{ "observedEvent": "id|type|event" }`.
//
fn recordTaskEvent(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, sent: ziggy.types.TaskSentEvent) void {
    _ = timers;
    const text = std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ sent.task_id, sent.task_type, sent.event_json }) catch @panic("out of memory");
    const message = ziggy.json.stringify(allocator, .{
        .observedEvent = text,
    }) catch @panic("out of memory");
    services.sendEvent(io, allocator, message) catch @panic("out of memory");
}

test "an app observes the end of a task and the events it sent" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var observed_app = helpers.app;
    observed_app.on_task_end = recordTaskEnd;
    observed_app.on_task_event = recordTaskEvent;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), observed_app);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"t1\",\"taskType\":\"quick\",\"source\":\"src\",\"data\":{\"a\":1},\"priority\":\"background\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"observedEnd\":\"t1|quick|src|{\\\"a\\\":1}|succeeded\"}");
    // Stopping the core waits for the workers, so every observer call has been made before the counts are read.
    native_app.stop(std.testing.io, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "\"observedEnd\""));
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "\"observedEvent\""));
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "{\"observedEvent\":\"t1|quick|{\\\"text\\\":\\\"hello\\\"}\"}"));
}

//
// The destroy test's on_destroy: tries to queue a task and sends the phase and the outcome as the app event
// `{ "destroyPhase": "phase|accepted" }` or `{ "destroyPhase": "phase|<error name>" }`, so the test reads them from the messages the
// fake native app recorded.
//
fn recordDestroyPhase(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, phase: ziggy.core.DestroyPhase) void {
    _ = timers;
    var outcome: []const u8 = "accepted";
    services.addTask(io, allocator, @tagName(phase), "quick", "destroy-test", "{}", .background) catch |err| {
        outcome = @errorName(err);
    };
    const text = std.fmt.allocPrint(allocator, "{s}|{s}", .{ @tagName(phase), outcome }) catch @panic("out of memory");
    const message = ziggy.json.stringify(allocator, .{
        .destroyPhase = text,
    }) catch @panic("out of memory");
    services.sendEvent(io, allocator, message) catch @panic("out of memory");
}

test "an app's on_destroy is called before tasks stop, while a task can still be queued, and again after the workers have stopped" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var destroyed_app = helpers.app;
    destroyed_app.on_destroy = recordDestroyPhase;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), destroyed_app);
    native_app.stop(std.testing.io, std.testing.allocator);
    const before = native_app.indexOfContaining(std.testing.io, std.testing.allocator, "{\"destroyPhase\":\"before_tasks_stop|accepted\"}") orelse return error.BeforeTasksStopNotCalled;
    const after = native_app.indexOfContaining(std.testing.io, std.testing.allocator, "{\"destroyPhase\":\"after_tasks_stopped|ShuttingDown\"}") orelse return error.AfterTasksStoppedNotCalled;
    try std.testing.expect(before < after);
    try std.testing.expectEqual(@as(usize, 2), native_app.countContaining(std.testing.io, std.testing.allocator, "\"destroyPhase\""));
}

//
// The create test's on_create: queues a task, which shows the worker pool is ready, and sends the app event `{ "created": true }`, so
// the test reads it from the messages the fake native app recorded.
//
fn recordCreate(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) anyerror!void {
    _ = arguments;
    _ = timers;
    try services.addTask(io, allocator, "created", "quick", "create-test", "{}", .background);
    try services.sendEvent(io, allocator, "{\"created\":true}");
}

test "an app's on_create is called once while the core is created, when a task can already be queued" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var created_app = helpers.app;
    created_app.on_create = recordCreate;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), created_app);
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "{\"created\":true}"));
    native_app.stop(std.testing.io, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "{\"created\":true}"));
}

//
// The thread test's on_create: sends the id of the thread it runs on as an app event.
//
fn recordCreateThread(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) anyerror!void {
    _ = arguments;
    _ = timers;
    var buffer: [64]u8 = undefined;
    try services.sendEvent(io, allocator, try std.fmt.bufPrint(&buffer, "{{\"createdOnThread\":{d}}}", .{std.Thread.getCurrentId()}));
}

test "an app's on_create runs on the core's main thread, not on the thread that creates the core" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var thread_app = helpers.app;
    thread_app.on_create = recordCreateThread;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), thread_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var expected_buffer: [64]u8 = undefined;
    const on_this_thread = try std.fmt.bufPrint(&expected_buffer, "{{\"createdOnThread\":{d}}}", .{std.Thread.getCurrentId()});
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "\"createdOnThread\":"));
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, on_this_thread));
}

//
// The failed create test's on_create: fails, as an app's would when it cannot make what its handlers need.
//
fn failCreate(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) anyerror!void {
    _ = arguments;
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    return error.AppCouldNotStart;
}

test "an app's on_create that fails makes the core's create fail with its error, and releases what the core made" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var failing_app = helpers.app;
    failing_app.on_create = failCreate;
    // The testing allocator fails the test if anything the core made is left unreleased.
    try std.testing.expectError(error.AppCouldNotStart, native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), failing_app));
}
