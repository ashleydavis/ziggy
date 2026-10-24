//
// The test control connection. It exists only in a build made with the test-hooks option, and lets a test script send
// commands to the running app over a loopback connection.
//
// A script connects to the port found in the port file and sends one line per command: a JSON object with a "command"
// field. A command the native app does (quit, menu, screenshot) is posted to the native app's queue as a call, and the connection waits
// on its own queue for the result of one that has one.
// Every other command goes to the core's main thread as a message, and the connection waits for the main thread's reply on a queue
// of its own: the main thread forwards a command for the frontend as a test-command event, the frontend performs it and replies with
// Ziggy's own test-result message, and the main thread sends that reply back. The reply is written back as one line. A line that is
// not a command gets an error as its reply.
//
// The main thread opens the listening socket and hands it to the accepting thread, which accepts each connection and hands it to a
// thread of its own. None of these threads shares anything with another: each is given copies of what it needs when it starts and
// makes its own Io, and talks to the others only by message. The accepting thread blocks in accept, and the main thread wakes it to
// read "stop" with a connection of its own. A connection thread blocks reading its socket, which the accepting thread accepted and
// closes once the connection thread has ended, and on stop the accepting thread ends its read by shutting the socket down.
//

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const json = @import("json.zig");
const message_queue = @import("message-queue.zig");
const dropped_files = @import("dropped-files.zig");

const MessageQueue = message_queue.MessageQueue;
const ThreadAllocator = @import("thread-allocator.zig").ThreadAllocator;
const NativeApp = @import("native-app.zig").NativeApp;
const worker_messages = @import("worker-messages.zig");

//
// The number the messages of a test control connection reach the main thread's queue under.
//
pub const from_test_control: u32 = 0xFFFF_FFF2;

//
// How long the frontend has to reply to a command, in milliseconds.
//
pub const answer_timeout_ms: u64 = 30_000;

//
// The number the main thread's messages reach the accepting thread's queue under, and the accepting thread's reach a connection
// thread's under. A connection thread's messages reach the accepting thread under the connection's number, which starts at 1.
//
const from_main: u32 = 0;

//
// A single threaded Io of the calling thread's own.
//
fn ownIo(allocator: std.mem.Allocator) std.Io.Threaded {
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    return threaded;
}

//
// The main thread's side of the control connection of one core.
//
pub const TestControl = struct {
    // The accepting thread's messages: "stop" from the main thread, and the ends of the connections. Allocated, so its address stays
    // the same however this struct is moved.
    queue: *MessageQueue,
    // The port it listens on.
    port: u16,
    // The thread that accepts connections.
    thread: std.Thread,

    //
    // Starts listening on a loopback port the operating system chooses, writes the port to the port file when there is one, and
    // starts the thread that accepts connections, which owns the listening socket from then on. `io` is the main thread's.
    //
    pub fn start(allocator: std.mem.Allocator, io: std.Io, config: types.ZiggyConfig, native: NativeApp, main_queue: *MessageQueue) !TestControl {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var server = try address.listen(io, .{});
        errdefer server.deinit(io);
        const port = server.socket.address.getPort();
        if (config.test_port_file) |port_file| {
            var port_buffer: [16]u8 = undefined;
            const port_text = try std.fmt.bufPrint(&port_buffer, "{d}\n", .{port});
            try std.Io.Dir.cwd().writeFile(io, .{
                .sub_path = std.mem.span(port_file),
                .data = port_text,
            });
        }
        const queue = try allocator.create(MessageQueue);
        errdefer allocator.destroy(queue);
        queue.* = MessageQueue.init();
        errdefer queue.deinit();
        const thread = try std.Thread.spawn(.{}, acceptConnections, .{AcceptStart{
            .native = .{
                .app = native,
                .has_quit = config.has_quit,
                .has_menu_action = config.has_menu_action,
                .has_screenshot = config.has_screenshot,
            },
            .main_queue = main_queue,
            .queue = queue,
            .server = server,
        }});
        return .{
            .queue = queue,
            .port = port,
            .thread = thread,
        };
    }

    //
    // Tells the accepting thread to stop accepting connections and end every connection. The main thread keeps replying to what the
    // connections send it, each with ShuttingDown, until the accepting thread sends it "test-control-stopped", then calls finishStop.
    // `io` is the main thread's.
    //
    pub fn beginStop(self: *TestControl, io: std.Io) void {
        self.queue.post(io, from_main, "{\"type\":\"stop\"}") catch @panic("out of memory stopping the test control connection");
        // The accepting thread blocks in accept, so a connection made here wakes it to read "stop".
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch unreachable;
        if (address.connect(io, .{ .mode = .stream })) |stream| {
            stream.close(io);
        }
        else |_| {}
    }

    //
    // Waits for the accepting thread to end and releases its queue, with the main thread's allocator, which `start` allocated it with.
    // Called once the accepting thread has sent "test-control-stopped".
    //
    pub fn finishStop(self: *TestControl, allocator: std.mem.Allocator) void {
        self.thread.join();
        self.queue.deinit();
        allocator.destroy(self.queue);
    }
};

//
// How a connection reaches the native app: its queue, and which of the calls the commands make the native app does.
//
const NativeAccess = struct {
    // The native app's queue and how to wake its UI thread.
    app: NativeApp,
    // Whether the native app does "quit" calls.
    has_quit: bool,
    // Whether the native app does "menu-action" calls.
    has_menu_action: bool,
    // Whether the native app does "screenshot" calls.
    has_screenshot: bool,
};

//
// What the accepting thread is given when it starts, which it owns from then on.
//
const AcceptStart = struct {
    // How the connections reach the native app, which each connection thread is given a copy of.
    native: NativeAccess,
    // The core's main thread's queue, where the commands that need the core go.
    main_queue: *MessageQueue,
    // The accepting thread's messages.
    queue: *MessageQueue,
    // The listening socket.
    server: std.Io.net.Server,
};

//
// One connection the accepting thread started a thread for.
//
const ConnectionThread = struct {
    // The connection's number, which its messages to the accepting thread carry.
    number: u32,
    // The connection thread's messages: "stop" from the accepting thread. Allocated, so its address stays the same.
    queue: *MessageQueue,
    // The connection's thread.
    thread: std.Thread,
    // The connection's socket, which the accepting thread accepted and closes once the connection thread has ended. The connection
    // thread reads and writes it and never closes it.
    stream: std.Io.net.Stream,
    // Whether the socket was closed already, to end the connection thread's read on Windows when stopping (wakeConnection).
    closed: bool,
};

//
// The accepting thread: accepts connections and starts a thread for each until it is sent "stop", then stops every connection thread,
// closes the listening socket and tells the main thread it has stopped.
//
fn acceptConnections(given: AcceptStart) void {
    var start = given;
    // The accepting thread's own allocator, which everything on its thread is allocated with.
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded = ownIo(allocator);
    defer threaded.deinit();
    const io = threaded.io();
    var connections: std.ArrayList(ConnectionThread) = .empty;
    defer connections.deinit(allocator);
    var next_number: u32 = 1;
    var stop_requested = false;
    while (!stop_requested) {
        const stream = start.server.accept(io) catch {
            continue;
        };
        while (start.queue.tryTake(io, allocator)) |message| {
            defer allocator.free(message.text);
            if (message.from == from_main) {
                stop_requested = true;
                continue;
            }
            endConnection(io, allocator, &connections, message.from);
        }
        if (stop_requested) {
            // The connection that woke this thread to read "stop".
            stream.close(io);
            break;
        }
        const connection_queue = allocator.create(MessageQueue) catch @panic("out of memory serving a test control connection");
        connection_queue.* = MessageQueue.init();
        const number = next_number;
        next_number += 1;
        const thread = std.Thread.spawn(.{}, serveConnection, .{ConnectionStart{
            .number = number,
            .native = start.native,
            .main_queue = start.main_queue,
            .accept_queue = start.queue,
            .queue = connection_queue,
            .stream = stream,
        }}) catch |err| {
            std.debug.print("test control: could not serve a connection: {s}\n", .{@errorName(err)});
            stream.close(io);
            connection_queue.deinit();
            allocator.destroy(connection_queue);
            continue;
        };
        connections.append(allocator, .{
            .number = number,
            .queue = connection_queue,
            .thread = thread,
            .stream = stream,
            .closed = false,
        }) catch @panic("out of memory serving a test control connection");
    }
    for (connections.items) |*connection| {
        connection.queue.post(io, from_main, "{\"type\":\"stop\"}") catch @panic("out of memory stopping the test control connection");
        wakeConnection(io, connection);
    }
    while (connections.items.len > 0) {
        const message = start.queue.take(io, allocator, .none) orelse {
            @panic("test control: the accepting thread's queue closed");
        };
        defer allocator.free(message.text);
        if (message.from != from_main) {
            endConnection(io, allocator, &connections, message.from);
        }
    }
    start.server.deinit(io);
    start.main_queue.post(io, from_test_control, "{\"type\":\"test-control-stopped\"}") catch @panic("out of memory stopping the test control connection");
}

//
// Ends a connection thread's read of its socket, so it reads "stop" and ends. Shutting the receiving side down wakes the read on
// Linux, macOS and Android. On Windows it does not, and closing the socket does, so there the socket is closed here and not again
// when the thread has ended.
//
fn wakeConnection(io: std.Io, connection: *ConnectionThread) void {
    if (builtin.os.tag == .windows) {
        connection.stream.close(io);
        connection.closed = true;
        return;
    }
    connection.stream.shutdown(io, .recv) catch |err| switch (err) {
        error.ConnectionAborted, error.ConnectionResetByPeer, error.SocketUnconnected => {},
        else => @panic("test control: could not shut a connection down"),
    };
}

//
// Waits for the thread of the connection that reported it ended, closes its socket and releases its queue.
//
fn endConnection(io: std.Io, allocator: std.mem.Allocator, connections: *std.ArrayList(ConnectionThread), number: u32) void {
    for (connections.items, 0..) |connection, index| {
        if (connection.number == number) {
            connection.thread.join();
            if (!connection.closed) {
                connection.stream.close(io);
            }
            connection.queue.deinit();
            allocator.destroy(connection.queue);
            _ = connections.swapRemove(index);
            return;
        }
    }
}

//
// What a connection thread is given when it starts, which it owns from then on.
//
const ConnectionStart = struct {
    // The connection's number, which its message to the accepting thread carries when it ends.
    number: u32,
    // How the thread reaches the native app.
    native: NativeAccess,
    // The core's main thread's queue, where the commands that need the core go.
    main_queue: *MessageQueue,
    // The accepting thread's queue, which the thread tells when it ends.
    accept_queue: *MessageQueue,
    // The connection thread's messages: "stop" from the accepting thread.
    queue: *MessageQueue,
    // The connection's socket, which the thread reads and writes. The accepting thread closes it once the thread has ended.
    stream: std.Io.net.Stream,
};

//
// A connection thread: serves the connection's commands until it closes or the thread is sent "stop", then closes the socket and tells
// the accepting thread it has ended. The command being run finishes first.
//
fn serveConnection(given: ConnectionStart) void {
    // The connection thread's own allocator, which everything on its thread is allocated with.
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    // The connection thread's own Io.
    var threaded = ownIo(allocator);
    defer threaded.deinit();
    const io = threaded.io();
    var connection: Connection = .{
        .start = given,
        .replies = MessageQueue.init(),
    };
    defer connection.replies.deinit();
    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;
    var reader = connection.start.stream.reader(io, &read_buffer);
    var writer = connection.start.stream.writer(io, &write_buffer);
    connection.serve(io, allocator, &reader.interface, &writer.interface);
    // The accepting thread closes the socket once this thread has ended.
    connection.start.accept_queue.post(io, connection.start.number, "{\"type\":\"ended\"}") catch @panic("out of memory ending a test control connection");
}

//
// A connection thread's own state, on its stack. It keeps no Io or allocator: each function is given the thread's own.
//
const Connection = struct {
    // What the thread was given.
    start: ConnectionStart,
    // Where the main thread's replies come.
    replies: MessageQueue,

    //
    // Reads commands and writes their replies until the connection closes or the thread is sent "stop".
    //
    fn serve(self: *Connection, io: std.Io, allocator: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) void {
        while (true) {
            if (self.stopRequested(io, allocator)) {
                return;
            }
            // Blocks until a command comes. On stop the accepting thread ends the read, which then fails or finds the end.
            const line = reader.takeDelimiter('\n') catch {
                return;
            } orelse {
                return;
            };
            var quit_after_reply = false;
            const reply_line = self.handleLine(io, allocator, line, &quit_after_reply) catch |err| blk: {
                const text = json.stringify(allocator, .{
                    .@"error" = @errorName(err),
                }) catch {
                    return;
                };
                break :blk text;
            };
            defer allocator.free(reply_line);
            writer.writeAll(reply_line) catch {
                return;
            };
            writer.writeAll("\n") catch {
                return;
            };
            writer.flush() catch {
                return;
            };
            if (quit_after_reply) {
                // The app is asked to quit only once the reply has gone. Quitting stops test control, which on Windows ends this
                // thread's read by closing the socket, and a reply still to be written was lost with it: Photosphere's Windows smoke
                // job reported "No answer from the control connection to quit".
                self.start.native.app.call(io, allocator, .quit, null) catch @panic("out of memory asking the native app to quit");
            }
        }
    }

    //
    // Whether the thread has been sent "stop".
    //
    fn stopRequested(self: *Connection, io: std.Io, allocator: std.mem.Allocator) bool {
        const message = self.start.queue.tryTake(io, allocator) orelse {
            return false;
        };
        allocator.free(message.text);
        return true;
    }

    //
    // Runs one command, a line holding a JSON object with a "command" field, and returns the reply line, allocated with
    // the allocator. A line that is not such an object gets an InvalidCommand error as its reply and nothing is run. A quit is not
    // run here: it sets `quit_after_reply`, and the caller asks the native app to quit once the reply is written.
    //
    fn handleLine(self: *Connection, io: std.Io, allocator: std.mem.Allocator, line: []const u8, quit_after_reply: *bool) ![]u8 {
        const native = self.start.native;
        const command_json = line;
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const command = std.json.parseFromSliceLeaky(std.json.Value, arena, command_json, .{}) catch {
            return try allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
        };
        const name = json.getString(command, "command") orelse {
            return try allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
        };
        if (std.mem.eql(u8, name, "quit")) {
            if (!native.has_quit) {
                return try allocator.dupe(u8, "{\"error\":\"NativeCallMissing\"}");
            }
            quit_after_reply.* = true;
            return try allocator.dupe(u8, "{\"ok\":true}");
        }
        if (std.mem.eql(u8, name, "menu")) {
            // Chooses a menu item as a user would, through the native app, so the native app's own actions really happen. Reloading unloads the
            // frontend, which is not listening again until it reports it is, so commands wait for that.
            const action = json.getString(command, "action") orelse {
                return try allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
            };
            if (!native.has_menu_action) {
                return try allocator.dupe(u8, "{\"error\":\"NativeCallMissing\"}");
            }
            try self.waitForUi(io, allocator);
            if (std.mem.eql(u8, action, "reload")) {
                try self.start.main_queue.post(io, from_test_control, "{\"type\":\"test-ui-reloading\"}");
            }
            try native.app.call(io, arena, .{
                .menu_action = action,
            }, null);
            return try allocator.dupe(u8, "{\"ok\":true}");
        }
        if (std.mem.eql(u8, name, "screenshot")) {
            // Writes a PNG of the app's window to the command's "outputPath" through the native app, which captures what is on screen.
            // The frontend must be showing first, or the picture would be of a window with nothing in it.
            const output_path = json.getString(command, "outputPath") orelse {
                return try allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
            };
            if (!native.has_screenshot) {
                return try allocator.dupe(u8, "{\"error\":\"NativeCallMissing\"}");
            }
            try self.waitForUi(io, allocator);
            // The native app's result comes back on the connection's own queue.
            try native.app.call(io, arena, .{
                .screenshot = output_path,
            }, .{
                .queue = &self.replies,
                .call_id = 0,
            });
            const reply = self.replies.take(io, arena, .none) orelse {
                @panic("test control: a connection's queue closed while it waited for a screenshot");
            };
            const response = try worker_messages.decode(worker_messages.INativeAppResponseMessage, arena, reply.text);
            if (response.@"error") |reason| {
                return try json.stringify(allocator, .{
                    .@"error" = reason,
                });
            }
            return try allocator.dupe(u8, "{\"ok\":true}");
        }
        if (std.mem.eql(u8, name, "drop")) {
            // Records a drop of files, as the native app does when the user drops files on the window, so a test can use getPathForFile
            // without dragging anything. The files are the command's "paths", an array of strings, checked here and recorded by the
            // main thread.
            const paths = command.object.get("paths") orelse {
                return try allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
            };
            const paths_json = try json.stringify(arena, paths);
            const files_json = dropped_files.check(arena, io, paths_json) catch |err| {
                return try json.stringify(allocator, .{
                    .@"error" = @errorName(err),
                });
            };
            const recorded = try self.callMain(io, allocator, try json.stringify(arena, .{
                .type = "test-drop",
                .files = json.Raw{
                    .text = files_json,
                },
            }));
            // A drop that names a "dataId" is also a drop on that element of the frontend, so the command is also sent to the
            // frontend, which drops the same files on it, and its reply is the reply.
            if (command.object.get("dataId") != null) {
                allocator.free(recorded);
                return try self.callUi(io, allocator, arena, command_json);
            }
            return recorded;
        }
        if (std.mem.eql(u8, name, "pick-answer")) {
            // Sets what the next native dialog returns, so a test can use the pickers without a dialog being shown. The result is
            // the command's "paths", an array of strings, and is used for one dialog.
            const paths = command.object.get("paths") orelse {
                return try allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
            };
            if (paths != .array) {
                return try allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
            }
            for (paths.array.items) |item| {
                if (item != .string) {
                    return try allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
                }
            }
            return try self.callMain(io, allocator, try json.stringify(arena, .{
                .type = "test-pick-answer",
                .paths = paths,
            }));
        }
        return try self.callUi(io, allocator, arena, command_json);
    }

    //
    // Waits until the frontend has reported it is listening, or fails with UiDidNotAnswer when it never does.
    //
    fn waitForUi(self: *Connection, io: std.Io, allocator: std.mem.Allocator) !void {
        const reply = try self.callMain(io, allocator, "{\"type\":\"test-wait-ui\"}");
        defer allocator.free(reply);
        if (!std.mem.eql(u8, reply, "{\"ok\":true}")) {
            return error.UiDidNotAnswer;
        }
    }

    //
    // Sends a command to the frontend, through the main thread, and waits for its reply.
    //
    fn callUi(self: *Connection, io: std.Io, allocator: std.mem.Allocator, arena: std.mem.Allocator, command_json: []const u8) ![]u8 {
        return try self.callMain(io, allocator, try json.stringify(arena, .{
            .type = "test-ui-command",
            .command = json.Raw{
                .text = command_json,
            },
        }));
    }

    //
    // Sends the main thread a message and waits for its reply, which it always sends, and returns the reply's text, allocated with
    // the allocator.
    //
    fn callMain(self: *Connection, io: std.Io, allocator: std.mem.Allocator, message: []const u8) ![]u8 {
        try self.start.main_queue.postReplyTo(io, from_test_control, message, &self.replies);
        const reply = self.replies.take(io, allocator, .none) orelse {
            @panic("test control: a connection's queue closed while it waited for the main thread");
        };
        return reply.text;
    }
};
