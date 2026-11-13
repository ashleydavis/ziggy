const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");
const test_app = @import("test-app.zig");
const test_tasks = @import("test-tasks.zig");
const FakeNativeApp = ziggy.fake_native_app.FakeNativeApp;

fn lastMessage(native_app: *FakeNativeApp) ![]u8 {
    return try native_app.messageAt(std.testing.io, std.testing.allocator, native_app.count(std.testing.io, std.testing.allocator) - 1);
}

//
// Fails unless the last message the fake native app recorded is the expected text.
//
fn expectLastMessage(native_app: *FakeNativeApp, expected: []const u8) !void {
    const last = try lastMessage(native_app);
    defer std.testing.allocator.free(last);
    try std.testing.expectEqualStrings(expected, last);
}

test "a message with an id reaches the app's message handler and its response comes back with the same id" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":7,\"name\":\"echo\",\"data\":{\"a\":1}}");
    const reply = try lastMessage(&native_app);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":7,\"ok\":true,\"data\":{\"a\":1}}", reply);
}

test "a string id is echoed as a string" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":\"abc\",\"name\":\"echo\",\"data\":null}");
    const reply = try lastMessage(&native_app);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":\"abc\",\"ok\":true,\"data\":null}", reply);
}

test "a system message name Ziggy does not know gets UnknownSystemMessage" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"nope\",\"data\":null}");
    const reply = try lastMessage(&native_app);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":1,\"ok\":false,\"error\":\"UnknownSystemMessage\"}", reply);
}

test "test-result and test-ui-ready are error replies when the core is not in test mode" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"test-result\",\"data\":{\"requestId\":1,\"result\":null}}");
    const first = try lastMessage(&native_app);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{\"id\":1,\"ok\":false,\"error\":\"RemoteControlNotRunning\"}", first);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"test-ui-ready\",\"data\":null}");
    const second = try lastMessage(&native_app);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("{\"id\":2,\"ok\":false,\"error\":\"RemoteControlNotRunning\"}", second);
}

test "malformed JSON is reported as a core-error event and the core keeps working" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":7,\"name\":\"name\",\"data\":null}");
    try expectLastMessage(&native_app, "{\"id\":7,\"ok\":true,\"data\":\"name\"}");
}

test "a message with no name, an empty name or a name that is not a string is refused with MissingMessageName before the handler runs" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var recording_app = test_app.app;
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":3,\"name\":\"nope\",\"data\":1}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":3,\"ok\":false,\"error\":\"UnknownMessageName\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"name\":\"fail\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"HandlerFailed\"}}");
}

test "a system message whose name is not a string is an invalid message" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":3,\"name\":7,\"data\":null}");
    try expectLastMessage(&native_app, "{\"id\":3,\"ok\":false,\"error\":\"InvalidMessage\"}");
}

test "a handler that returns none with an id gets an empty successful response, and without an id gets nothing" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"name\":\"none\"}");
    try std.testing.expectEqual(@as(usize, 0), native_app.count(std.testing.io, std.testing.allocator));
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":9,\"name\":\"none\"}");
    try expectLastMessage(&native_app, "{\"id\":9,\"ok\":true,\"data\":null}");
}

test "core.sendEvent delivers the data as an app event" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var recording_app = test_app.app;
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var recording_app = test_app.app;
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var recording_app = test_app.app;
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"name\":\"echo\",\"data\":1}");
    try std.testing.expectEqual(@as(usize, 0), native_app.count(std.testing.io, std.testing.allocator));
}

test "a handler that fails becomes an error reply" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":4,\"name\":\"fail\"}");
    const reply = try lastMessage(&native_app);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":4,\"ok\":false,\"error\":\"HandlerFailed\"}", reply);
}

test "get-platform reports the platform kind" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 3, 2);
    native_app.stop(std.testing.io, std.testing.allocator);
}

test "create without a wake callback fails" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.wake = null;
    try std.testing.expectError(error.WakeCallbackMissing, native_app.start(std.testing.io, std.testing.allocator, config, test_app.app));
}

test "a menu-action message naming a .ui item reaches the UI as the app event menu; no menu-action event is sent" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"zig-item\"}}");
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "the menu item's function ran"));
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{}}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"menu-action\",\"data\":{\"action\":\"failing-item\"}}");
    try expectLastMessage(&native_app, "{\"id\":2,\"ok\":false,\"error\":\"MenuItemFailed\"}");
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "\"type\":\"menu\""));
}

test "a menu-action message naming an unknown item or a standard action fails with UnknownMenuItem and runs nothing" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"nonsense\"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":false,\"error\":\"UnknownMenuItem\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"menu-action\",\"data\":{\"action\":\"quit\"}}");
    try expectLastMessage(&native_app, "{\"id\":2,\"ok\":false,\"error\":\"UnknownMenuItem\"}");
    try std.testing.expectEqual(@as(usize, 2), native_app.count(std.testing.io, std.testing.allocator));
}

test "a menu-action message with no action is an error reply" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"action\\\" is missing\"}");
}

test "a menu-action message naming an .action item's action sends the frontend the action system event" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"say-hello\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"action\",\"data\":{\"action\":\"say-hello\"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{}}");
}

test "a menu-action message naming an action that is not on the menu, as its shortcut posts, sends the action system event" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"shortcut-only\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"action\",\"data\":{\"action\":\"shortcut-only\"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{}}");
}

test "a run-action message naming an app action sends the frontend the action system event" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"run-action\",\"data\":{\"action\":\"say-hello\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"action\",\"data\":{\"action\":\"say-hello\"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{}}");
}

test "a run-action message naming a standard action of the menu has a desktop's native app run it" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.has_native_call = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, test_app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"run-action\",\"data\":{\"action\":\"quit\"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{}}");
    const actions = try native_app.chosenActions(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(actions);
    try std.testing.expectEqualStrings("quit\n", actions);
}

test "a run-action message naming an unknown name, or a standard action the menu does not have, fails with UnknownAction" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.has_native_call = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, test_app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"run-action\",\"data\":{\"action\":\"nonsense\"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":false,\"error\":\"UnknownAction\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"run-action\",\"data\":{\"action\":\"toggle-devtools\"}}");
    try expectLastMessage(&native_app, "{\"id\":2,\"ok\":false,\"error\":\"UnknownAction\"}");
    const actions = try native_app.chosenActions(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(actions);
    try std.testing.expectEqualStrings("", actions);
}

test "a run-action message naming a standard action fails with StandardActionUnavailable on a mobile or with no menu_action callback" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    // A mobile's core.
    var mobile_config = native_app.config(1, 1);
    mobile_config.is_mobile = true;
    try native_app.start(std.testing.io, std.testing.allocator, mobile_config, test_app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"run-action\",\"data\":{\"action\":\"quit\"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":false,\"error\":\"StandardActionUnavailable\"}");

    var desktop: FakeNativeApp = undefined;
    desktop.init();
    defer desktop.deinit(std.testing.io, std.testing.allocator);
    var config = desktop.config(1, 1);
    config.has_native_call = false;
    config.has_menu_action = false;
    try desktop.start(std.testing.io, std.testing.allocator, config, test_app.app);
    defer desktop.stop(std.testing.io, std.testing.allocator);
    try desktop.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"run-action\",\"data\":{\"action\":\"quit\"}}");
    try expectLastMessage(&desktop, "{\"id\":1,\"ok\":false,\"error\":\"StandardActionUnavailable\"}");
}

test "a list-actions message answers every action and standard item with its label and its shortcut as the platform shows it" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    // A desktop app that does its own native calls, as Photosphere's does, still lists its shortcuts.
    var config = native_app.config(1, 1);
    config.has_native_call = true;
    try native_app.start(std.testing.io, std.testing.allocator, config, test_app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"list-actions\"}");
    const expected = if (builtin.os.tag == .macos)
        "{\"id\":1,\"ok\":true,\"data\":[{\"name\":\"say-hello\",\"label\":\"Say Hello\",\"shortcut\":\"⇧⌘H\"}," ++
            "{\"name\":\"shortcut-only\",\"label\":\"Shortcut Only\",\"shortcut\":\"⇧⌘O\"}," ++
            "{\"name\":\"typing-only\",\"label\":\"Typing Only\",\"shortcut\":\"Escape\"}," ++
            "{\"name\":\"ask\",\"label\":\"Ask\",\"shortcut\":\"?\"}," ++
            "{\"name\":\"quit\",\"label\":\"Quit\",\"shortcut\":\"⌘Q\"}]}"
    else
        "{\"id\":1,\"ok\":true,\"data\":[{\"name\":\"say-hello\",\"label\":\"Say Hello\",\"shortcut\":\"Ctrl+Shift+H\"}," ++
            "{\"name\":\"shortcut-only\",\"label\":\"Shortcut Only\",\"shortcut\":\"Ctrl+Shift+O\"}," ++
            "{\"name\":\"typing-only\",\"label\":\"Typing Only\",\"shortcut\":\"Escape\"}," ++
            "{\"name\":\"ask\",\"label\":\"Ask\",\"shortcut\":\"?\"}," ++
            "{\"name\":\"quit\",\"label\":\"Quit\",\"shortcut\":\"Ctrl+Q\"}]}";
    try expectLastMessage(&native_app, expected);
}

test "a list-actions message on a mobile answers no shortcuts" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.is_mobile = true;
    try native_app.start(std.testing.io, std.testing.allocator, config, test_app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"list-actions\"}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":[{\"name\":\"say-hello\",\"label\":\"Say Hello\",\"shortcut\":null}," ++
        "{\"name\":\"shortcut-only\",\"label\":\"Shortcut Only\",\"shortcut\":null},{\"name\":\"typing-only\",\"label\":\"Typing Only\",\"shortcut\":null}," ++
        "{\"name\":\"ask\",\"label\":\"Ask\",\"shortcut\":null},{\"name\":\"quit\",\"label\":\"Quit\",\"shortcut\":null}]}");
}

test "a list-shortcuts message answers every shortcut of the menu and the actions, standards included" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    // A desktop app that does its own native calls still gets its shortcuts.
    var config = native_app.config(1, 1);
    config.has_native_call = true;
    try native_app.start(std.testing.io, std.testing.allocator, config, test_app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"list-shortcuts\"}");
    // CmdOrCtrl is Ctrl on Linux and Windows and Command on macOS.
    const expected = if (builtin.os.tag == .macos)
        "{\"id\":1,\"ok\":true,\"data\":[" ++
            "{\"action\":\"say-hello\",\"standard\":false,\"text_box\":false,\"code\":\"\",\"ctrl\":false,\"alt\":false,\"shift\":true,\"meta\":true,\"shiftOptional\":false,\"key\":\"h\"}," ++
            "{\"action\":\"nested\",\"standard\":false,\"text_box\":false,\"code\":\"\",\"ctrl\":false,\"alt\":false,\"shift\":true,\"meta\":true,\"shiftOptional\":false,\"key\":\"n\"}," ++
            "{\"action\":\"shortcut-only\",\"standard\":false,\"text_box\":false,\"code\":\"\",\"ctrl\":false,\"alt\":false,\"shift\":true,\"meta\":true,\"shiftOptional\":false,\"key\":\"o\"}," ++
            "{\"action\":\"typing-only\",\"standard\":false,\"text_box\":true,\"code\":\"Escape\",\"ctrl\":false,\"alt\":false,\"shift\":false,\"meta\":false,\"shiftOptional\":false,\"key\":\"\"}," ++
            "{\"action\":\"ask\",\"standard\":false,\"text_box\":true,\"code\":\"\",\"ctrl\":false,\"alt\":false,\"shift\":false,\"meta\":false,\"shiftOptional\":true,\"key\":\"?\"}," ++
            "{\"action\":\"quit\",\"standard\":true,\"text_box\":false,\"code\":\"\",\"ctrl\":false,\"alt\":false,\"shift\":false,\"meta\":true,\"shiftOptional\":false,\"key\":\"q\"}]}"
    else
        "{\"id\":1,\"ok\":true,\"data\":[" ++
            "{\"action\":\"say-hello\",\"standard\":false,\"text_box\":false,\"code\":\"\",\"ctrl\":true,\"alt\":false,\"shift\":true,\"meta\":false,\"shiftOptional\":false,\"key\":\"h\"}," ++
            "{\"action\":\"nested\",\"standard\":false,\"text_box\":false,\"code\":\"\",\"ctrl\":true,\"alt\":false,\"shift\":true,\"meta\":false,\"shiftOptional\":false,\"key\":\"n\"}," ++
            "{\"action\":\"shortcut-only\",\"standard\":false,\"text_box\":false,\"code\":\"\",\"ctrl\":true,\"alt\":false,\"shift\":true,\"meta\":false,\"shiftOptional\":false,\"key\":\"o\"}," ++
            "{\"action\":\"typing-only\",\"standard\":false,\"text_box\":true,\"code\":\"Escape\",\"ctrl\":false,\"alt\":false,\"shift\":false,\"meta\":false,\"shiftOptional\":false,\"key\":\"\"}," ++
            "{\"action\":\"ask\",\"standard\":false,\"text_box\":true,\"code\":\"\",\"ctrl\":false,\"alt\":false,\"shift\":false,\"meta\":false,\"shiftOptional\":true,\"key\":\"?\"}," ++
            "{\"action\":\"quit\",\"standard\":true,\"text_box\":false,\"code\":\"\",\"ctrl\":true,\"alt\":false,\"shift\":false,\"meta\":false,\"shiftOptional\":false,\"key\":\"q\"}]}";
    try expectLastMessage(&native_app, expected);
}

test "a list-shortcuts message on a mobile answers none" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.is_mobile = true;
    try native_app.start(std.testing.io, std.testing.allocator, config, test_app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"list-shortcuts\"}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":[]}");
}

test "a handler's services.runAction sends the frontend the action system event" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"run-an-action\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"action\",\"data\":{\"action\":\"say-hello\"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":null}");
}

test "the app holds its menu for native apps to read" {
    const entries = comptime ziggy.menu.menuEntries(test_app.menu, test_app.actions);
    try std.testing.expectEqual(entries.len, test_app.app.menu_entries.len);
    for (entries, test_app.app.menu_entries) |wanted, entry| {
        try std.testing.expectEqual(wanted.kind, entry.kind);
        try std.testing.expectEqual(wanted.depth, entry.depth);
    }
    try std.testing.expect(test_app.app.menu_targets.get("zig-item") != null);
}

test "a file of the app's bundled UI is found by the path of a request" {
    try std.testing.expectEqualStrings("<html></html>", ziggy.ui_files.findFile(test_app.app.ui_files, "/index.html").?.content);
    try std.testing.expectEqualStrings("index.html", ziggy.ui_files.findFile(test_app.app.ui_files, "/").?.path);
    try std.testing.expect(ziggy.ui_files.findFile(test_app.app.ui_files, "/missing.js") == null);
}

test "respondWithTask answers the message with the task's result, without blocking the dispatcher" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 2, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":11,\"name\":\"quick-request\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":11,\"ok\":true,\"data\":\"done\"}");
    // The reply is the only thing sent: a request's task sends no task-completed event of its own.
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "task-completed"));
}

test "a message answered by a task that fails gets an error response" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 2, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":12,\"name\":\"fail-request\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":12,\"ok\":false,\"error\":\"TestFailure\"}");
}

test "a message with no id whose response is to be a task's result is refused and queues nothing" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 2, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":13,\"name\":\"pick-open-request\",\"data\":\"Choose files\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":13,\"ok\":true,\"data\":[\"kind0\",\"Choose files\",\"-\"]}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":14,\"name\":\"pick-save-request\",\"data\":\"photo.jpg\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":14,\"ok\":true,\"data\":[\"kind1\",\"-\",\"photo.jpg\"]}");
}

test "a dialog with no callback from the native app is an error reply naming what is missing" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(2, 1);
    config.has_pick_paths = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, test_app.app);
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 2, 2);
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
    // Whether the native app is a mobile's.
    isMobile: bool,
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
        .isMobile = services.isMobile(),
        .dataDir = services.dataDir(),
    };
}

//
// The app of the handler services tests: the tests' app (test-app.zig) with native-services.
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
    registered.tasks = &test_tasks.task_handlers;
    break :registered registered;
};

test "the handler services reach the native app's quit and menu action callbacks and report its data directory and kind" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    // The data directory is only reported, never written to, by this app.
    var config = native_app.config(1, 1);
    config.data_dir = "/tmp";
    config.is_mobile = true;
    try native_app.start(std.testing.io, std.testing.allocator, config, native_services_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"native-services\"}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{\"isMobile\":true,\"dataDir\":\"/tmp\"}}");
    try std.testing.expect(native_app.quitCalled(std.testing.io, std.testing.allocator));
    const actions = try native_app.chosenActions(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(actions);
    try std.testing.expectEqualStrings("focus-window\n", actions);
}

test "the handler services report a desktop's native app, which has no native call callback, and quit and menu actions it lacks change nothing" {
    var native_app: FakeNativeApp = undefined;
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
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{\"isMobile\":false,\"dataDir\":\"/tmp\"}}");
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
    var thread_allocator: ziggy.utils.thread_allocator.ThreadAllocator = .init;
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
    registered.tasks = &test_tasks.task_handlers;
    break :registered registered;
};

test "a thread of the app's own sends the frontend events and makes native calls through the native callbacks it was given" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), callbacks_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"native-callbacks\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"from\":\"a thread of the app's own\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"nativeCallResult\":{\"method\":\"exportFile\",\"request\":{\"key\":1}}}}");
}

test "the native callbacks of a native app with no native call callback have no native caller" {
    var native_app: FakeNativeApp = undefined;
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var described_app = test_app.app;
    described_app.describe_error = describeTestError;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), described_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":4,\"name\":\"fail\"}");
    const reply = try lastMessage(&native_app);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":4,\"ok\":false,\"error\":\"the handler failed because the test chose to\"}", reply);
}

test "an error the describer has no description for is replied to by name" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var described_app = test_app.app;
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var described_app = test_app.app;
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var observed_app = test_app.app;
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var destroyed_app = test_app.app;
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var created_app = test_app.app;
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var thread_app = test_app.app;
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
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var failing_app = test_app.app;
    failing_app.on_create = failCreate;
    // The testing allocator fails the test if anything the core made is left unreleased.
    try std.testing.expectError(error.AppCouldNotStart, native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), failing_app));
}

//
// The app of the config and state file tests: an app named core-test, which opens the top-level keys `top` and the table `open`, but nothing
// else, to the frontend.
//
const files_app = registered: {
    var copy = test_app.app;
    copy.name = "core-test";
    copy.title = "Core test";
    
    
    break :registered copy;
};

//
// The directories of the config and state files the file tests use, under a directory of the test's own.
//
const FileDirectories = struct {
    // The directory of the config file.
    config_dir: []const u8,
    // The directory of the state file.
    state_dir: []const u8,
};

//
// Sets the process environment so the core's files go in directories of the test's own, and returns their paths.
//
fn setUpFileDirectories(
    tmp: *std.testing.TmpDir,
    arena_state: *std.heap.ArenaAllocator,
    map: *std.process.Environ.Map,
) !FileDirectories {
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const config_dir = try std.fs.path.join(arena, &.{ root, "config" });
    const state_dir = try std.fs.path.join(arena, &.{ root, "state" });
    map.* = try std.testing.environ.createMap(std.testing.allocator);
    try map.put(try ziggy.config_state.platform.appVariableName(arena, "core-test", "_CONFIG_DIR"), config_dir);
    try map.put(try ziggy.config_state.platform.appVariableName(arena, "core-test", "_STATE_DIR"), state_dir);
    ziggy.utils.process_env.setEnvironMap(map);
    return .{ .config_dir = config_dir, .state_dir = state_dir };
}

//
// Sends a system message with the given id, name and data text.
//
fn sendSystem(native_app: *FakeNativeApp, id: u32, name: []const u8, data: []const u8) !void {
    const message = try std.fmt.allocPrint(std.testing.allocator, "{{\"kind\":\"system\",\"id\":{d},\"name\":\"{s}\",\"data\":{s}}}", .{ id, name, data });
    defer std.testing.allocator.free(message);
    native_app.sendMessage(std.testing.allocator, message);
}

test "get-config, set-config, get-state and set-state round trip through top-level and dotted paths, and a null removes a key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    const directories = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();
    const arena = arena_state.allocator();

    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), files_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);

    try sendSystem(&native_app, 1, "set-config", "{\"path\":\"top\",\"value\":\"blue\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true,\"data\":null}");
    try sendSystem(&native_app, 2, "get-config", "\"top\"");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":true,\"data\":\"blue\"}");
    try sendSystem(&native_app, 3, "set-config", "{\"path\":\"open.a.b\",\"value\":7}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":3,\"ok\":true,\"data\":null}");
    try sendSystem(&native_app, 4, "get-config", "\"open.a.b\"");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":4,\"ok\":true,\"data\":7}");

    try sendSystem(&native_app, 5, "set-state", "{\"path\":\"top\",\"value\":\"remembered\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":5,\"ok\":true,\"data\":null}");
    try sendSystem(&native_app, 6, "get-state", "\"top\"");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":6,\"ok\":true,\"data\":\"remembered\"}");

    try sendSystem(&native_app, 7, "set-config", "{\"path\":\"top\",\"value\":null}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":7,\"ok\":true,\"data\":null}");
    try sendSystem(&native_app, 8, "get-config", "\"top\"");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":8,\"ok\":true,\"data\":null}");

    const config_path = try std.fs.path.join(arena, &.{ directories.config_dir, "config.toml" });
    const config_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, arena, .limited(1024 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, config_text, "b = 7") != null);
}


test "get-config-problem reports a bad line, set-config refuses the file and logs the problem, and the start-up log names it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    const directories = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();
    const arena = arena_state.allocator();
    const config_path = try std.fs.path.join(arena, &.{ directories.config_dir, "config.toml" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, directories.config_dir);
    const bad = "top = \"blue\"\noops = = 1\n";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = bad });

    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), files_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);

    try sendSystem(&native_app, 1, "get-config-problem", "null");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"id\":1,\"ok\":true,\"data\":{\"path\":");
    try sendSystem(&native_app, 2, "set-config", "{\"path\":\"top\",\"value\":\"green\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":false,\"error\":\"ConfigFileInvalid\"}");
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, arena, .limited(1024 * 1024));
    try std.testing.expectEqualStrings(bad, after);

    const logs_dir = try std.fs.path.join(arena, &.{ std.mem.sliceTo(&native_app.data_dir_path, 0), "logs" });
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, logs_dir, .{ .iterate = true });
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    var found = false;
    while (try iterator.next(std.testing.io)) |entry| {
        const text = try directory.readFileAlloc(std.testing.io, entry.name, arena, .limited(1024 * 1024));
        if (std.mem.indexOf(u8, text, "has an error on line 2") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "the file messages answer AppNameMissing for a core built for no app" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);

    try sendSystem(&native_app, 1, "get-config", "\"top\"");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"AppNameMissing\"}");
    try sendSystem(&native_app, 2, "set-config", "{\"path\":\"top\",\"value\":1}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":false,\"error\":\"AppNameMissing\"}");
    try sendSystem(&native_app, 3, "get-state", "\"top\"");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":3,\"ok\":false,\"error\":\"AppNameMissing\"}");
    try sendSystem(&native_app, 4, "set-state", "{\"path\":\"top\",\"value\":1}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":4,\"ok\":false,\"error\":\"AppNameMissing\"}");
}

test "the start-up log names a missing state file and an unreadable one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    const directories = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();
    const arena = arena_state.allocator();

    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), files_app);
    native_app.stop(std.testing.io, std.testing.allocator);
    const logs_dir = try std.fs.path.join(arena, &.{ std.mem.sliceTo(&native_app.data_dir_path, 0), "logs" });
    try expectLogLine(arena, logs_dir, "does not exist yet, so the app starts with an empty state");

    const state_path = try std.fs.path.join(arena, &.{ directories.state_dir, "state.json" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, directories.state_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = state_path, .data = "not json" });
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), files_app);
    native_app.stop(std.testing.io, std.testing.allocator);
    try expectLogLine(arena, logs_dir, "could not be read (it is not JSON");
}

//
// Fails unless one of the log files in the directory holds the text.
//
fn expectLogLine(arena: std.mem.Allocator, logs_dir: []const u8, text: []const u8) !void {
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, logs_dir, .{ .iterate = true });
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        const log_text = try directory.readFileAlloc(std.testing.io, entry.name, arena, .limited(1024 * 1024));
        if (std.mem.indexOf(u8, log_text, text) != null) {
            return;
        }
    }
    return error.LogLineMissing;
}

test "set-config with theme writes the config file, sends config-changed and sends the native call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    const directories = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();
    const arena = arena_state.allocator();

    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), files_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try sendSystem(&native_app, 1, "set-config", "{\"path\":\"theme\",\"value\":\"dark\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"config-changed\",\"data\":{\"path\":\"theme\",\"value\":\"dark\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true,\"data\":null}");
    const call = try native_app.lastCall(std.testing.io, std.testing.allocator, "theme");
    defer if (call) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"type\":\"theme\",\"setting\":\"dark\",\"theme\":\"dark\",\"background\":\"#000000\"}", call.?);
    const config_path = try std.fs.path.join(arena, &.{ directories.config_dir, "config.toml" });
    const config_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, arena, .limited(1024 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, config_text, "theme = \"dark\"") != null);
}

test "set-config with theme in a core started with --theme dark applies the value and get-config gives it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    const directories = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();
    const arena = arena_state.allocator();

    const arguments = [_][:0]const u8{ "--theme", "dark" };
    var pointers: [arguments.len][*:0]const u8 = undefined;
    for (arguments, 0..) |argument, index| {
        pointers[index] = argument.ptr;
    }
    var config = native_app.config(1, 1);
    config.arg_count = arguments.len;
    config.args = &pointers;
    try native_app.start(std.testing.io, std.testing.allocator, config, files_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try sendSystem(&native_app, 1, "set-config", "{\"path\":\"theme\",\"value\":\"light\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true,\"data\":null}");
    try sendSystem(&native_app, 2, "get-config", "\"theme\"");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":true,\"data\":\"light\"}");
    const config_path = try std.fs.path.join(arena, &.{ directories.config_dir, "config.toml" });
    const config_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, arena, .limited(1024 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, config_text, "theme = \"light\"") != null);
}

test "set-config with theme in a core built for no app fails with AppNameMissing" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try test_app.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try sendSystem(&native_app, 1, "set-config", "{\"path\":\"theme\",\"value\":\"dark\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"AppNameMissing\"}");
}

test "set-config with theme in a bad config file fails with ConfigFileInvalid and leaves the file as it was" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    const directories = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();
    const arena = arena_state.allocator();
    const config_path = try std.fs.path.join(arena, &.{ directories.config_dir, "config.toml" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, directories.config_dir);
    const bad = "theme = \"dark\"\noops = = 1\n";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = bad });

    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), files_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try sendSystem(&native_app, 1, "set-config", "{\"path\":\"theme\",\"value\":\"light\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"ConfigFileInvalid\"}");
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, arena, .limited(1024 * 1024));
    try std.testing.expectEqualStrings(bad, after);
}

test "get-system-theme answers the operating system's theme whatever the setting is" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    _ = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();

    var config = native_app.config(1, 1);
    config.system_theme = 0;
    try native_app.start(std.testing.io, std.testing.allocator, config, files_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try sendSystem(&native_app, 1, "get-system-theme", "null");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true,\"data\":\"light\"}");

    native_app.stop(std.testing.io, std.testing.allocator);
    config.system_theme = 1;
    try native_app.start(std.testing.io, std.testing.allocator, config, files_app);
    try sendSystem(&native_app, 2, "get-system-theme", "null");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":true,\"data\":\"dark\"}");
}

test "system-theme sends the native call when the theme changes and none when it does not" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    _ = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();

    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), files_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try sendSystem(&native_app, 1, "system-theme", "\"dark\"");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true,\"data\":null}");
    const call = try native_app.lastCall(std.testing.io, std.testing.allocator, "theme");
    defer if (call) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"type\":\"theme\",\"setting\":\"system\",\"theme\":\"dark\",\"background\":\"#000000\"}", call.?);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"config-changed\",\"data\":{\"path\":\"theme\",\"value\":\"system\"}}");

    var light_app = files_app;
    light_app.backgrounds = .{};
    const light_arguments = [_][:0]const u8{ "--theme", "light" };
    var light_pointers: [light_arguments.len][*:0]const u8 = undefined;
    for (light_arguments, 0..) |argument, index| {
        light_pointers[index] = argument.ptr;
    }
    var light_config = native_app.config(1, 1);
    light_config.arg_count = light_arguments.len;
    light_config.args = &light_pointers;
    native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, light_config, light_app);
    try sendSystem(&native_app, 2, "system-theme", "\"dark\"");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":true,\"data\":null}");
    const none = try native_app.lastCall(std.testing.io, std.testing.allocator, "theme");
    defer if (none) |text| std.testing.allocator.free(text);
    try std.testing.expect(none == null);
}

