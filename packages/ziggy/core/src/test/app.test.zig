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

test "a message reaches the handler for its name with its data parsed into the handler's request, and the response is the returned struct" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"greet\",\"data\":{\"name\":\"Ada\",\"times\":2,\"title\":\"Dr \"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{\"text\":\"Hello Dr Ada\",\"times\":2}}");
}

test "a field the request gives a default, or that is optional, may be left out, and a field the request does not have is ignored" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"greet\",\"data\":{\"name\":\"Ada\",\"colour\":\"blue\"}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{\"text\":\"Hello Ada\",\"times\":1}}");
}

test "data with a required field missing is InvalidMessageData naming the field, and the handler does not run" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"forget\",\"data\":{\"times\":3}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"name\\\" is missing\"}");
    // A message with no data is parsed as an empty object, so it too names the missing field.
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"forget\"}");
    try expectLastMessage(&native_app, "{\"id\":2,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"name\\\" is missing\"}");
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "forgot"));
}

test "data with a field of the wrong type is InvalidMessageData naming the field, and the handler does not run" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"forget\",\"data\":{\"name\":\"Ada\",\"times\":\"many\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"times\\\" does not fit (");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"forget\",\"data\":{\"name\":\"Ada\",\"times\":-1}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"times\\\" does not fit (");
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "forgot"));
}

test "data that is not an object, for a request that is a struct, is InvalidMessageData" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"forget\",\"data\":\"Ada\"}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the data is not an object\"}");
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "forgot"));
}

test "a request that is not a struct is parsed too, and data that does not fit it is InvalidMessageData" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"count\",\"data\":[4,5,6]}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":3}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"count\",\"data\":{\"a\":1}}");
    try expectLastMessage(&native_app, "{\"id\":2,\"ok\":false,\"error\":\"InvalidMessageData: UnexpectedToken\"}");
}

test "data that does not fit a message sent with no id is a core-error event" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"name\":\"forget\",\"data\":7}");
    try expectLastMessage(&native_app, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"InvalidMessageData: the data is not an object\"}}");
}

test "a handler that returns nothing answers a message with an id with null" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"forget\",\"data\":{\"name\":\"Ada\",\"times\":4}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":null}");
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "forgot Ada 4"));
}

test "a name the app has no handler for is UnknownMessageName" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"greet-everyone\",\"data\":null}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":false,\"error\":\"UnknownMessageName\"}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"name\":\"Greet\",\"data\":null}");
    try expectLastMessage(&native_app, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"UnknownMessageName\"}}");
}

test "a handler that takes ziggy.core.Message gets the message unparsed, and can answer with a task" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"echo\",\"data\":{\"anything\":[1,\"two\"]}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{\"anything\":[1,\"two\"]}}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"quick-request\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":true,\"data\":\"done\"}");
}

//
// A task handler for the test of App's task table.
//
fn tableTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, payload: std.json.Value) !void {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = payload;
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
    try std.testing.expect(registered.tasks[1].handler == ziggy.task_runner.wrapTask("the task type \"kept-alive\"", tableTask));
    try std.testing.expectEqual(@as(usize, 0), registered.messages.len);
    try std.testing.expect(registered.describe_error == null);
    try std.testing.expect(registered.ui_query == null);
}

//
// A task handler of the raw TaskHandler form, whose result is JSON text already.
//
fn rawTableTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, payload: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = payload;
    return "{\"raw\":true}";
}

test "App uses a task handler of the raw TaskHandler form as it is, so its JSON result is not written again as a string" {
    const registered = ziggy.core.App(.{
        .messages = .{},
        .tasks = .{
            .raw = rawTableTask,
        },
        .menu = &.{},
        .ui_files = &[_]ziggy.ui_files.UiFile{},
    });
    try std.testing.expect(registered.tasks[0].handler == &rawTableTask);
}

//
// The reply the later handler was given for the first message that sends its response later in a new core. The main thread numbers
// those messages from 0, so the test holds the same reply as the handler, which a handler would hand to another thread: the main
// thread's queue and the serial. The app has no describe_error.
//
fn firstLaterReply(native_app: *helpers.FakeNativeApp) ziggy.core.Reply(helpers.GreetResponse) {
    return .{
        .target = .{
            .queue = &native_app.queue,
            .describe_error = null,
            .serial = 0,
        },
    };
}

//
// now: gives its response at once through Response.
//
fn nowHandler(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, payload: helpers.GreetRequest) !ziggy.core.Response(helpers.GreetResponse) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .now = .{
            .text = try std.fmt.allocPrint(allocator, "Now {s}", .{payload.name}),
            .times = payload.times,
        },
    };
}

//
// task: its response is the result of the sleep task, given the payload, which names the sleep after the payload's name.
//
fn taskHandler(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, payload: helpers.GreetRequest) !ziggy.core.Response([]const u8) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "sleep",
            .data = try ziggy.json.stringify(allocator, payload),
        },
    };
}

//
// later: sends its response later, leaving the test to send it through the reply (see firstLaterReply).
//
fn laterHandler(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, payload: helpers.GreetRequest, reply: ziggy.core.Reply(helpers.GreetResponse)) !ziggy.core.Response(helpers.GreetResponse) {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = payload;
    if (reply.target.serial != 0) {
        std.debug.panic("the later handler was given reply {d}, and the tests use reply 0", .{reply.target.serial});
    }
    return .later;
}

//
// sent-and-now: sends its response through its reply and then again by what it returns, which is two responses.
//
fn sentAndNowHandler(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, payload: helpers.GreetRequest, reply: ziggy.core.Reply(helpers.GreetResponse)) !ziggy.core.Response(helpers.GreetResponse) {
    _ = services;
    _ = timers;
    try reply.send(io, allocator, .{
        .text = payload.name,
        .times = 1,
    });
    return .{
        .now = .{
            .text = payload.name,
            .times = 2,
        },
    };
}

//
// later-without-reply: returns that it sends its response later but has no reply to do it with.
//
fn laterWithoutReplyHandler(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, payload: helpers.GreetRequest) !ziggy.core.Response(helpers.GreetResponse) {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = payload;
    return .later;
}

//
// The app of the tests of Response and Reply.
//
const reply_app = registered: {
    var registered = ziggy.core.App(.{
        .messages = .{
            .now = nowHandler,
            .task = taskHandler,
            .later = laterHandler,
            .@"sent-and-now" = sentAndNowHandler,
            .@"later-without-reply" = laterWithoutReplyHandler,
        },
        .tasks = .{},
        .menu = &.{},
        .ui_files = &[_]ziggy.ui_files.UiFile{},
    });
    registered.tasks = &helpers.task_handlers;
    break :registered registered;
};

test "a handler that returns Response .now is answered at once with the value" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), reply_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"now\",\"data\":{\"name\":\"Ada\",\"times\":3}}");
    try expectLastMessage(&native_app, "{\"id\":1,\"ok\":true,\"data\":{\"text\":\"Now Ada\",\"times\":3}}");
}

test "a handler that returns Response .task is answered with the task's result" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), reply_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"task\",\"data\":{\"name\":\"Ada\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"start\":\"Ada\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true,\"data\":null}");
}

test "a handler that sends its response later through its reply, from another thread, gets it sent only once" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), reply_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":\"x\",\"name\":\"later\",\"data\":{\"name\":\"Ada\"}}");
    try std.testing.expectEqual(@as(usize, 0), native_app.count(std.testing.io, std.testing.allocator));
    const reply = firstLaterReply(&native_app);
    const sender = try std.Thread.spawn(.{}, sendLater, .{reply});
    sender.join();
    try native_app.handled(std.testing.io, std.testing.allocator);
    try expectLastMessage(&native_app, "{\"id\":\"x\",\"ok\":true,\"data\":{\"text\":\"Later\",\"times\":5}}");
    // A response sent through a reply reaches the main thread as a message, so a second one is refused there, with a core-error event,
    // instead of by what send returns.
    try reply.send(std.testing.io, std.testing.allocator, .{
        .text = "again",
        .times = 6,
    });
    try native_app.handled(std.testing.io, std.testing.allocator);
    try expectLastMessage(&native_app, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"MessageAlreadyAnswered\"}}");
    try reply.fail(std.testing.io, std.testing.allocator, error.TooLate);
    try native_app.handled(std.testing.io, std.testing.allocator);
    try expectLastMessage(&native_app, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"MessageAlreadyAnswered\"}}");
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "\"ok\":true"));
    try std.testing.expectEqual(@as(usize, 3), native_app.count(std.testing.io, std.testing.allocator));
}

//
// Sends the later message's response, on a thread of its own, with an Io and an allocator of its own.
//
fn sendLater(reply: ziggy.core.Reply(helpers.GreetResponse)) void {
    var thread_allocator: ziggy.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = thread_allocator.allocator();
    defer threaded.deinit();
    reply.send(threaded.io(), thread_allocator.allocator(), .{
        .text = "Later",
        .times = 5,
    }) catch |err| {
        std.debug.panic("the reply could not be sent: {s}", .{@errorName(err)});
    };
}

test "a reply that fails gives the message an error response" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), reply_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"later\",\"data\":{\"name\":\"Ada\"}}");
    try firstLaterReply(&native_app).fail(std.testing.io, std.testing.allocator, error.LaterFailure);
    try native_app.handled(std.testing.io, std.testing.allocator);
    try expectLastMessage(&native_app, "{\"id\":2,\"ok\":false,\"error\":\"LaterFailure\"}");
}

test "a response through the reply and another by what the handler returns is reported as a core-error event, not a second response" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), reply_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":3,\"name\":\"sent-and-now\",\"data\":{\"name\":\"Ada\"}}");
    // The response the handler sent through its reply reaches the main thread after the handler has returned, so it may come after the
    // message the fake native app waited on.
    try native_app.handled(std.testing.io, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), native_app.count(std.testing.io, std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 1), native_app.countContaining(std.testing.io, std.testing.allocator, "{\"id\":3,\"ok\":true,\"data\":{\"text\":\"Ada\",\"times\":2}}"));
    try expectLastMessage(&native_app, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"MessageAlreadyAnswered\"}}");
}

test "a handler with no reply that returns .later is MessageNotAnswered" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), reply_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":4,\"name\":\"later-without-reply\",\"data\":{\"name\":\"Ada\"}}");
    try expectLastMessage(&native_app, "{\"id\":4,\"ok\":false,\"error\":\"MessageNotAnswered\"}");
}

test "a reply that never sends a response is reported as a core-error event when the core stops" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), reply_app);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":5,\"name\":\"later\",\"data\":{\"name\":\"Ada\"}}");
    try std.testing.expectEqual(@as(usize, 0), native_app.count(std.testing.io, std.testing.allocator));
    native_app.stop(std.testing.io, std.testing.allocator);
    try expectLastMessage(&native_app, "{\"kind\":\"system\",\"name\":\"core-error\",\"data\":{\"error\":\"MessageNotAnswered: later\"}}");
}

test "a handler that takes ziggy.core.Message gets the raw data, the name and the id" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":9,\"name\":\"raw\",\"data\":[1,{\"a\":null}]}");
    try expectLastMessage(&native_app, "{\"id\":9,\"ok\":true,\"data\":{\"name\":\"raw\",\"id\":9,\"data\":[1,{\"a\":null}]}}");
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":10,\"name\":\"none\",\"data\":7}");
    try expectLastMessage(&native_app, "{\"id\":10,\"ok\":true,\"data\":null}");
}
