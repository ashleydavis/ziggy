//
// Checks the core's remote control connection. Each test starts a WebSocket server of its own, which plays the remote control
// server, gives its address to the core as the configuration's remote_control, and sends the core commands as the server would
// pass them on from a test script.
//

const std = @import("std");
const ziggy = @import("ziggy");
const helpers = @import("helpers.zig");
const RemoteControlServer = @import("remote-control-server.zig").RemoteControlServer;

//
// One command sent to the core, and its reply once finish has read it.
//
const Client = struct {
    // The server the core is connected to.
    server: *RemoteControlServer,
    // The line to send.
    line: []const u8,
    // The reply, once finish has read it, allocated with the testing allocator.
    response: ?[]u8,

    fn init(server: *RemoteControlServer, line: []const u8) Client {
        return .{
            .server = server,
            .line = line,
            .response = null,
        };
    }

    //
    // Sends the line.
    //
    fn start(self: *Client) !void {
        try self.server.send(self.line);
    }

    //
    // Waits for the reply.
    //
    fn finish(self: *Client) void {
        self.response = self.server.reply() catch |err| std.debug.panic("no reply from the core: {s}", .{@errorName(err)});
    }
};

//
// Starts a core in test mode connected to the server, and waits for the server to see the connection.
//
fn startControlledCore(native_app: *helpers.FakeNativeApp, server: *RemoteControlServer) !void {
    var config = native_app.config(1, 1);
    config.test_mode = true;
    config.remote_control = server.address();
    try native_app.start(std.testing.io, std.testing.allocator, config, helpers.app);
    try server.expectConnected();
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

test "an app's on_create that fails in test mode stops the remote control connection the core started" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.test_mode = true;
    config.remote_control = server.address();
    var failing_app = helpers.app;
    failing_app.on_create = failCreate;
    // The testing allocator fails the test if the connection the core started is left unreleased, and the server sees it closed.
    try std.testing.expectError(error.AppCouldNotStart, native_app.start(std.testing.io, std.testing.allocator, config, failing_app));
    try server.expectConnected();
    try server.expectClosed();
}

test "a command reaches the UI and its result comes back" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(&server, "{\"command\":\"click\",\"dataId\":\"go\"}");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-ui-ready\",\"data\":null}");
    try client.start();
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"kind\":\"system\",\"name\":\"test-command\",\"data\":{\"requestId\":1,\"command\":{\"command\":\"click\",\"dataId\":\"go\"}}");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":9,\"name\":\"test-result\",\"data\":{\"requestId\":1,\"result\":{\"clicked\":true}}}");
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"clicked\":true}", client.response.?);
}

test "the core connects to the remote control address and answers commands" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    // The connection to the server is the remote control connection: it reads the command and refuses it as invalid.
    const reply = try responseFor(&server, "{\"command\":\"drop\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", reply);
}

test "a line that is not JSON gets an error reply and never reaches the UI" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(&server, "this is not json");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.response.?);
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "test-command"));
}

test "a JSON object with no command field gets an error reply and never reaches the UI" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(&server, "{\"dataId\":\"x\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.response.?);
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "test-command"));
}

test "the quit command calls the native app's quit callback" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(&server, "{\"command\":\"quit\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.response.?);
    try native_app.expectQuitCalled(std.testing.io, std.testing.allocator);
}

test "a core started without a remote control address does not connect" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), helpers.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    // A remote control connection is made before the core's start returns, so one that has not come by now never will.
    try std.testing.expect(!server.hasEventWithin(300));
}

test "a refused connection fails the core's start" {
    // A server that is started and stopped again leaves a port that refuses connections.
    var server: RemoteControlServer = undefined;
    try server.start();
    var address_buffer: [32]u8 = undefined;
    const address = try std.fmt.bufPrintZ(&address_buffer, "{s}", .{std.mem.span(server.address())});
    server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.test_mode = true;
    config.remote_control = address.ptr;
    // The testing allocator fails the test if the connection thread's queue is left unreleased.
    try std.testing.expectError(error.RemoteControlConnectFailed, native_app.start(std.testing.io, std.testing.allocator, config, helpers.app));
}

test "an address with no port fails the core's start" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.test_mode = true;
    config.remote_control = "127.0.0.1";
    try std.testing.expectError(error.RemoteControlConnectFailed, native_app.start(std.testing.io, std.testing.allocator, config, helpers.app));
}

test "splitAddress takes the port after the last colon and refuses an address without a host or a port" {
    const split = ziggy.remote_control.splitAddress("127.0.0.1:4001").?;
    try std.testing.expectEqualStrings("127.0.0.1", split.host);
    try std.testing.expectEqual(@as(u16, 4001), split.port);
    try std.testing.expect(ziggy.remote_control.splitAddress("127.0.0.1") == null);
    try std.testing.expect(ziggy.remote_control.splitAddress(":4001") == null);
    try std.testing.expect(ziggy.remote_control.splitAddress("127.0.0.1:0") == null);
    try std.testing.expect(ziggy.remote_control.splitAddress("127.0.0.1:port") == null);
    try std.testing.expect(ziggy.remote_control.splitAddress("127.0.0.1:70000") == null);
}

test "a test-result nobody is waiting for is an error reply" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"test-result\",\"data\":{\"requestId\":99,\"result\":1}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"UnexpectedTestResult\"}");
}

test "stopping the core ends the connection thread, which closes the connection" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    // The connection thread is waiting in its read, with no command coming, when the core stops.
    native_app.stop(std.testing.io, std.testing.allocator);
    try server.expectClosed();
}

test "a core still stops after the server closed the connection" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    try server.closeConnection();
    try server.expectClosed();
    // The connection thread has ended its read and waits to be told to stop, which the core's stop does.
    native_app.stop(std.testing.io, std.testing.allocator);
}

test "a command is held until the UI reports it is listening" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(&server, "{\"command\":\"ready\"}");
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
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(&server, "{\"command\":\"pick-answer\",\"paths\":[\"/picked/one.txt\",\"/picked/two.txt\"]}");
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
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(&server, "{\"command\":\"pick-answer\",\"paths\":[1,2]}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.response.?);
}

test "the menu command chooses the menu item through the native app's callback once the UI is listening" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(&server, "{\"command\":\"menu\",\"action\":\"zoom-in\"}");
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
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-ui-ready\",\"data\":null}");
    var reload = Client.init(&server, "{\"command\":\"menu\",\"action\":\"reload\"}");
    try reload.start();
    reload.finish();
    defer if (reload.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", reload.response.?);
    var next = Client.init(&server, "{\"command\":\"ready\"}");
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
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.test_mode = true;
    config.remote_control = server.address();
    config.has_menu_action = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, helpers.app);
    try server.expectConnected();
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(&server, "{\"command\":\"menu\",\"action\":\"zoom-in\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"NativeCallMissing\"}", client.response.?);
}

test "the drop command records a drop the way the native app does, so the UI can request the paths of a drop" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
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
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    // The path is written as a JSON string, so a Windows path's backslashes are escaped.
    const line = try ziggy.json.stringify(std.testing.allocator, .{
        .command = "drop",
        .paths = &[_][]const u8{path},
    });
    defer std.testing.allocator.free(line);
    var client = Client.init(&server, line);
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
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
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
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const line = try ziggy.json.stringify(std.testing.allocator, .{
        .command = "drop",
        .dataId = "zone",
        .paths = &[_][]const u8{path},
    });
    defer std.testing.allocator.free(line);
    var client = Client.init(&server, line);
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
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-ui-ready\",\"data\":null}");
    var client = Client.init(&server, "{\"command\":\"screenshot\",\"outputPath\":\"/shots/home.png\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.response.?);
    const paths = try native_app.screenshotPaths(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(paths);
    try std.testing.expectEqualStrings("/shots/home.png\n", paths);
}

test "the screenshot command replies with the reason when the native app cannot capture the window" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"test-ui-ready\",\"data\":null}");
    var client = Client.init(&server, "{\"command\":\"screenshot\",\"outputPath\":\"/shots/refused.png\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"The window cannot be captured.\"}", client.response.?);
}

test "the screenshot command without an output path is an invalid command and captures nothing" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(&server, "{\"command\":\"screenshot\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.response.?);
    const paths = try native_app.screenshotPaths(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(paths);
    try std.testing.expectEqualStrings("", paths);
}

test "the screenshot command on a native app with no screenshot callback reports what is missing" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.test_mode = true;
    config.remote_control = server.address();
    config.has_screenshot = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, helpers.app);
    try server.expectConnected();
    defer native_app.stop(std.testing.io, std.testing.allocator);
    var client = Client.init(&server, "{\"command\":\"screenshot\",\"outputPath\":\"/shots/home.png\"}");
    try client.start();
    client.finish();
    defer if (client.response) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"NativeCallMissing\"}", client.response.?);
}

//
// Sends one line to the core's remote control connection and returns its reply, allocated with the testing allocator.
//
fn responseFor(server: *RemoteControlServer, line: []const u8) ![]u8 {
    try server.send(line);
    return try server.reply();
}

test "the quit command on a native app with no quit callback reports what is missing" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    config.test_mode = true;
    config.remote_control = server.address();
    config.has_quit = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, helpers.app);
    try server.expectConnected();
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const response = try responseFor(&server, "{\"command\":\"quit\"}");
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("{\"error\":\"NativeCallMissing\"}", response);
}

test "the menu command without an action is an invalid command and chooses nothing" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const response = try responseFor(&server, "{\"command\":\"menu\"}");
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", response);
    const actions = try native_app.chosenActions(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(actions);
    try std.testing.expectEqualStrings("", actions);
}

test "the drop command without paths is an invalid command" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const response = try responseFor(&server, "{\"command\":\"drop\"}");
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", response);
}

test "a dialog result with no paths, or with paths that are not an array, is refused" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const missing = try responseFor(&server, "{\"command\":\"pick-answer\"}");
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", missing);
    const not_array = try responseFor(&server, "{\"command\":\"pick-answer\",\"paths\":\"/one.txt\"}");
    defer std.testing.allocator.free(not_array);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", not_array);
}

test "second paths for the next dialog replace the first" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const first = try responseFor(&server, "{\"command\":\"pick-answer\",\"paths\":[\"/first.txt\"]}");
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{\"ok\":true}", first);
    const second = try responseFor(&server, "{\"command\":\"pick-answer\",\"paths\":[\"/second.txt\"]}");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("{\"ok\":true}", second);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"app\",\"id\":31,\"name\":\"pick-open-request\",\"data\":\"Title\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":31,\"ok\":true,\"data\":[\"/second.txt\"]}");
}

test "a test-result without a request id is an error reply" {
    var server: RemoteControlServer = undefined;
    try server.start();
    defer server.stop();
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startControlledCore(&native_app, &server);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":5,\"name\":\"test-result\",\"data\":{\"result\":null}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":5,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"requestId\\\" is missing\"}");
}
