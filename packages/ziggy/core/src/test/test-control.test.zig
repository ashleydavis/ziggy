const std = @import("std");
const ziggy = @import("ziggy");
const helpers = @import("helpers.zig");

//
// One client conversation with the control connection, run on its own thread because the reply waits for the frontend. The test's
// thread and the client's share nothing: the client's thread is sent the line to send as a message, and sends back the reply, or that
// there was none, as a message.
//
const Client = struct {
    // The port to connect to.
    port: u16,
    // The line to send, without the newline.
    line: []const u8,
    // The client thread's messages: the line to send.
    messages: ziggy.message_queue.MessageQueue,
    // Where the client thread sends the reply: the line, from 0, or nothing, from 1, when the connection was closed without a reply.
    results: ziggy.message_queue.MessageQueue,
    // The client's thread.
    thread: std.Thread,
    // The line the connection replied with, once finish has read it, allocated with the testing allocator.
    response: ?[]u8,
    // Whether the connection was closed without a reply, once finish has read it.
    closed_without_response: bool,

    fn init(port: u16, line: []const u8) Client {
        return .{
            .port = port,
            .line = line,
            .messages = .init(),
            .results = .init(),
            .thread = undefined,
            .response = null,
            .closed_without_response = false,
        };
    }

    //
    // Starts the client's thread and sends it the line.
    //
    fn start(self: *Client) !void {
        try self.messages.post(std.testing.io, 0, self.line);
        self.thread = try std.Thread.spawn(.{}, run, .{ &self.messages, &self.results, self.port });
    }

    //
    // Waits for the client's thread to end and reads what it sent back.
    //
    fn finish(self: *Client) void {
        self.thread.join();
        const result = self.results.take(std.testing.io, std.testing.allocator, .none) orelse @panic("the client's result queue closed");
        if (result.from == 1) {
            std.testing.allocator.free(result.text);
            self.closed_without_response = true;
        }
        else {
            self.response = result.text;
        }
        self.messages.deinit();
        self.results.deinit();
    }

    fn run(messages: *ziggy.message_queue.MessageQueue, results: *ziggy.message_queue.MessageQueue, port: u16) void {
        var thread_allocator: ziggy.thread_allocator.ThreadAllocator = .init;
        defer thread_allocator.deinit();
        const allocator = thread_allocator.allocator();
        var threaded: std.Io.Threaded = .init_single_threaded;
        threaded.allocator = allocator;
        defer threaded.deinit();
        const io = threaded.io();
        const line = messages.take(io, allocator, .none) orelse @panic("the client's message queue closed");
        defer allocator.free(line.text);
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch @panic("bad address");
        const stream = address.connect(io, .{ .mode = .stream }) catch @panic("could not connect to the control connection");
        defer stream.close(io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);
        writer.interface.writeAll(line.text) catch @panic("write failed");
        writer.interface.writeAll("\n") catch @panic("write failed");
        writer.interface.flush() catch @panic("write failed");
        const response = reader.interface.takeDelimiter('\n') catch {
            results.post(io, 1, "") catch @panic("out of memory");
            return;
        } orelse {
            results.post(io, 1, "") catch @panic("out of memory");
            return;
        };
        results.post(io, 0, response) catch @panic("out of memory");
    }
};

fn startControlledCore(native_app: *helpers.FakeNativeApp, tmp: *std.testing.TmpDir) !void {
    var config = native_app.config(1, 1);
    var port_file_buffer: [256]u8 = undefined;
    const port_file = try std.fmt.bufPrintZ(&port_file_buffer, ".zig-cache/tmp/{s}/port.txt", .{tmp.sub_path});
    config.test_mode = true;
    config.test_port_file = port_file.ptr;
    try native_app.start(std.testing.io, std.testing.allocator, config, helpers.app);
}

//
// The port of the control connection, which it writes to the port file in the test's directory before the core's start returns.
//
fn controlPort(tmp: *std.testing.TmpDir) !u16 {
    var buffer: [32]u8 = undefined;
    const text = try tmp.dir.readFile(std.testing.io, "port.txt", &buffer);
    return try std.fmt.parseInt(u16, std.mem.trim(u8, text, "\n"), 10);
}

//
// The failed create test's on_create: fails, as an app's would when it cannot make what its handlers need.
//
fn failCreate(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!void {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    return error.AppCouldNotStart;
}

test "an app's on_create that fails in test mode stops the control connection the core started" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    var port_file_buffer: [256]u8 = undefined;
    const port_file = try std.fmt.bufPrintZ(&port_file_buffer, ".zig-cache/tmp/{s}/port.txt", .{tmp.sub_path});
    config.test_mode = true;
    config.test_port_file = port_file.ptr;
    var failing_app = helpers.app;
    failing_app.on_create = failCreate;
    // The testing allocator fails the test if the control connection the core started is left unreleased.
    try std.testing.expectError(error.AppCouldNotStart, native_app.start(std.testing.io, std.testing.allocator, config, failing_app));
}

test "a command reaches the UI and its result comes back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(try controlPort(&tmp), "{\"command\":\"click\",\"dataId\":\"go\"}");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-ui-ready\",\"data\":null}");
    try client.start();
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"kind\":\"system\",\"name\":\"test-command\",\"data\":{\"requestId\":1,\"command\":{\"command\":\"click\",\"dataId\":\"go\"}}");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":9,\"name\":\"test-result\",\"data\":{\"requestId\":1,\"result\":{\"clicked\":true}}}");
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"clicked\":true}", client.response.?);
}

test "the port is written to the port file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    // The connection on the port in the file is the control connection: it reads the command and refuses it as invalid.
    const reply = try responseFor(&tmp, "{\"command\":\"drop\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", reply);
}

test "a line that is not JSON gets an error reply and never reaches the UI" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(try controlPort(&tmp), "this is not json");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.response.?);
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "test-command"));
}

test "a JSON object with no command field gets an error reply and never reaches the UI" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(try controlPort(&tmp), "{\"dataId\":\"x\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.response.?);
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "test-command"));
}

test "the quit command calls the native app's quit callback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(try controlPort(&tmp), "{\"command\":\"quit\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.response.?);
    try native_app.expectQuitCalled(std.testing.io, std.testing.allocator);
}

test "a core not in test mode has no control connection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    var port_file_buffer: [256]u8 = undefined;
    const port_file = try std.fmt.bufPrintZ(&port_file_buffer, ".zig-cache/tmp/{s}/port.txt", .{tmp.sub_path});
    config.test_port_file = port_file.ptr;
    try native_app.start(std.testing.io, std.testing.allocator, config, helpers.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    // A control connection writes its port to the file before the core's start returns, and none was started.
    try std.testing.expectError(error.FileNotFound, controlPort(&tmp));
}

test "a test-result nobody is waiting for is an error reply" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"test-result\",\"data\":{\"requestId\":99,\"result\":1}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"UnexpectedTestResult\"}");
}

test "a second connection is served while the first stays open, and stopping ends both" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", try controlPort(&tmp));
    // The first connection is opened and left open, and sends nothing.
    const first = try address.connect(io, .{ .mode = .stream });
    defer first.close(io);
    var client = Client.init(try controlPort(&tmp), "this is not json");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.response.?);
    // Stopping the core must not wait for the first connection to close.
    native_app.stop(std.testing.io, std.testing.allocator);
}

test "a command is held until the UI reports it is listening" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(try controlPort(&tmp), "{\"command\":\"ready\"}");
    try client.start();
    // The frontend has not reported it is listening, so the command is not sent to it.
    ziggy.fake_native_app.sleepMs(std.testing.io, 300);
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "test-command"));
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-ui-ready\",\"data\":null}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"kind\":\"system\",\"name\":\"test-command\"");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-result\",\"data\":{\"requestId\":1,\"result\":{\"ok\":true}}}");
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.response.?);
}

test "a test's paths for the next dialog are used once and then the native app's dialog is shown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(try controlPort(&tmp), "{\"command\":\"pick-answer\",\"paths\":[\"/picked/one.txt\",\"/picked/two.txt\"]}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.response.?);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"app\",\"id\":21,\"name\":\"pick-open-request\",\"data\":\"Title\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":21,\"ok\":true,\"data\":[\"/picked/one.txt\",\"/picked/two.txt\"]}");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"app\",\"id\":22,\"name\":\"pick-open-request\",\"data\":\"Title\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":22,\"ok\":true,\"data\":[\"kind0\",\"Title\",\"-\"]}");
}

test "paths for a dialog that are not an array of strings are refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(try controlPort(&tmp), "{\"command\":\"pick-answer\",\"paths\":[1,2]}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.response.?);
}

test "the menu command chooses the menu item through the native app's callback once the UI is listening" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(try controlPort(&tmp), "{\"command\":\"menu\",\"action\":\"zoom-in\"}");
    try client.start();
    // The frontend is not listening yet, so nothing is chosen.
    ziggy.fake_native_app.sleepMs(std.testing.io, 300);
    const before = try native_app.chosenActions(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(before);
    try std.testing.expectEqualStrings("", before);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-ui-ready\",\"data\":null}");
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.response.?);
    const actions = try native_app.chosenActions(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(actions);
    try std.testing.expectEqualStrings("zoom-in\n", actions);
}

test "choosing reload holds commands until the UI reports it is listening again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-ui-ready\",\"data\":null}");
    var reload = Client.init(try controlPort(&tmp), "{\"command\":\"menu\",\"action\":\"reload\"}");
    try reload.start();
    reload.finish();
    defer if (reload.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", reload.response.?);
    var next = Client.init(try controlPort(&tmp), "{\"command\":\"ready\"}");
    try next.start();
    // The frontend is reloading, so the next command is held back and not sent to it.
    ziggy.fake_native_app.sleepMs(std.testing.io, 300);
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "test-command"));
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-ui-ready\",\"data\":null}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"kind\":\"system\",\"name\":\"test-command\"");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-result\",\"data\":{\"requestId\":1,\"result\":{\"ok\":true}}}");
    next.finish();
    defer if (next.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", next.response.?);
}

test "the menu command on a native app with no menu callback reports what is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    var port_file_buffer: [256]u8 = undefined;
    const port_file = try std.fmt.bufPrintZ(&port_file_buffer, ".zig-cache/tmp/{s}/port.txt", .{tmp.sub_path});
    config.test_mode = true;
    config.test_port_file = port_file.ptr;
    config.has_menu_action = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, helpers.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(try controlPort(&tmp), "{\"command\":\"menu\",\"action\":\"zoom-in\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"NativeCallMissing\"}", client.response.?);
}

test "the drop command records a drop the way the native app does, so the UI can request the paths of a drop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dropped.txt",
        .data = "xyz",
    });
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "dropped.txt" });
    defer std.testing.allocator.free(path);
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    // The path is written as a JSON string, so a Windows path's backslashes are escaped.
    const line = try ziggy.json.stringify(std.testing.allocator, .{
        .command = "drop",
        .paths = &[_][]const u8{path},
    });
    defer std.testing.allocator.free(line);
    var client = Client.init(try controlPort(&tmp), line);
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.response.?);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":31,\"name\":\"get-dropped-paths\",\"data\":null}");
    const expected = try ziggy.json.stringify(std.testing.allocator, .{
        .id = 31,
        .ok = true,
        .data = &[_][]const u8{path},
    });
    defer std.testing.allocator.free(expected);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, expected);
}

test "a drop that names an element is also sent to the UI, and the UI's result is the reply" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dropped.txt",
        .data = "xyz",
    });
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "dropped.txt" });
    defer std.testing.allocator.free(path);
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const line = try ziggy.json.stringify(std.testing.allocator, .{
        .command = "drop",
        .dataId = "zone",
        .paths = &[_][]const u8{path},
    });
    defer std.testing.allocator.free(line);
    var client = Client.init(try controlPort(&tmp), line);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-ui-ready\",\"data\":null}");
    try client.start();
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"kind\":\"system\",\"name\":\"test-command\",\"data\":{\"requestId\":1,\"command\":{\"command\":\"drop\",\"dataId\":\"zone\"");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":9,\"name\":\"test-result\",\"data\":{\"requestId\":1,\"result\":{\"dropped\":true}}}");
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"dropped\":true}", client.response.?);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":32,\"name\":\"get-dropped-paths\",\"data\":null}");
    const expected = try ziggy.json.stringify(std.testing.allocator, .{
        .id = 32,
        .ok = true,
        .data = &[_][]const u8{path},
    });
    defer std.testing.allocator.free(expected);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, expected);
}

test "the screenshot command has the native app write a picture of the window to the path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-ui-ready\",\"data\":null}");
    var client = Client.init(try controlPort(&tmp), "{\"command\":\"screenshot\",\"outputPath\":\"/shots/home.png\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.response.?);
    const paths = try native_app.screenshotPaths(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(paths);
    try std.testing.expectEqualStrings("/shots/home.png\n", paths);
}

test "the screenshot command replies with the reason when the native app cannot capture the window" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-ui-ready\",\"data\":null}");
    var client = Client.init(try controlPort(&tmp), "{\"command\":\"screenshot\",\"outputPath\":\"/shots/refused.png\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"The window cannot be captured.\"}", client.response.?);
}

test "the screenshot command without an output path is an invalid command and captures nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(try controlPort(&tmp), "{\"command\":\"screenshot\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.response.?);
    const paths = try native_app.screenshotPaths(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(paths);
    try std.testing.expectEqualStrings("", paths);
}

test "the screenshot command on a native app with no screenshot callback reports what is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    var port_file_buffer: [256]u8 = undefined;
    const port_file = try std.fmt.bufPrintZ(&port_file_buffer, ".zig-cache/tmp/{s}/port.txt", .{tmp.sub_path});
    config.test_mode = true;
    config.test_port_file = port_file.ptr;
    config.has_screenshot = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, helpers.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(try controlPort(&tmp), "{\"command\":\"screenshot\",\"outputPath\":\"/shots/home.png\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"NativeCallMissing\"}", client.response.?);
}

//
// Sends one line to the control connection of a core and returns its reply, allocated with the testing allocator.
//
fn responseFor(tmp: *std.testing.TmpDir, line: []const u8) ![]u8 {
    var client = Client.init(try controlPort(tmp), line);
    try client.start();
    client.finish();
    return client.response orelse error.ClosedWithoutResponse;
}

test "the quit command on a native app with no quit callback reports what is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    var port_file_buffer: [256]u8 = undefined;
    const port_file = try std.fmt.bufPrintZ(&port_file_buffer, ".zig-cache/tmp/{s}/port.txt", .{tmp.sub_path});
    config.test_mode = true;
    config.test_port_file = port_file.ptr;
    config.has_quit = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, helpers.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const response = try responseFor(&tmp, "{\"command\":\"quit\"}");
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("{\"error\":\"NativeCallMissing\"}", response);
}

test "the menu command without an action is an invalid command and chooses nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const response = try responseFor(&tmp, "{\"command\":\"menu\"}");
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", response);
    const actions = try native_app.chosenActions(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(actions);
    try std.testing.expectEqualStrings("", actions);
}

test "the drop command without paths is an invalid command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const response = try responseFor(&tmp, "{\"command\":\"drop\"}");
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", response);
}

test "a dialog result with no paths, or with paths that are not an array, is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const missing = try responseFor(&tmp, "{\"command\":\"pick-answer\"}");
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", missing);
    const not_array = try responseFor(&tmp, "{\"command\":\"pick-answer\",\"paths\":\"/one.txt\"}");
    defer std.testing.allocator.free(not_array);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", not_array);
}

test "second paths for the next dialog replace the first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const first = try responseFor(&tmp, "{\"command\":\"pick-answer\",\"paths\":[\"/first.txt\"]}");
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{\"ok\":true}", first);
    const second = try responseFor(&tmp, "{\"command\":\"pick-answer\",\"paths\":[\"/second.txt\"]}");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("{\"ok\":true}", second);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"app\",\"id\":31,\"name\":\"pick-open-request\",\"data\":\"Title\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":31,\"ok\":true,\"data\":[\"/second.txt\"]}");
}

test "a test-result without a request id is an error reply" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &tmp);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":5,\"name\":\"test-result\",\"data\":{\"result\":null}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":5,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"requestId\\\" is missing\"}");
}
