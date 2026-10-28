//
// The remote control connection. Its code is in every build and does nothing unless the native app was started with
// `--remote-control <host:port>`, which sets the configuration's `remote_control`. The core then connects out to the remote control
// server at that address, and a test script talks to the server, which passes each line the script writes to the app and each
// reply back to the script.
//
// The connection is one WebSocket connection to `ws://<host:port>/`. Each text message is one command: a JSON object with a
// "command" field. A command the native app does (quit, menu, screenshot) is posted to the native app's queue as a call, and the
// connection waits on its own queue for the result of one that has one. Every other command goes to the core's main thread as a
// message, and the connection waits for the main thread's reply on a queue of its own: the main thread forwards a command for the
// frontend as a test-command event, the frontend performs it and replies with Ziggy's own test-result message, and the main thread
// sends that reply back. The reply is sent as one text message. A message that is not a command gets an error as its reply.
//
// One thread owns the connection. It is given copies of what it needs when it starts, makes its own Io and allocator, and talks to
// the main thread only by message. It connects, tells the main thread whether it did, and then blocks reading the connection. The
// one thing the main thread holds of the connection is a copy of the socket's handle, sent in that first message: on stop it posts
// "stop" and shuts the socket down, which ends the thread's read. On Linux, macOS and Android the shutdown itself ends the read. On
// Windows it does not, but the shutdown sends the server the end of the connection, the server closes its side, and that ends the
// read. The thread closes the socket only after it has taken "stop", so the handle the main thread shuts down is never one the
// system has given to something else.
//

const std = @import("std");
const builtin = @import("builtin");
const websocket = @import("websocket");
const types = @import("types.zig");
const json = @import("json.zig");
const message_queue = @import("message-queue.zig");
const dropped_files = @import("dropped-files.zig");

const MessageQueue = message_queue.MessageQueue;
const ThreadAllocator = @import("thread-allocator.zig").ThreadAllocator;
const NativeApp = @import("native-app.zig").NativeApp;
const worker_messages = @import("worker-messages.zig");

//
// The number the messages of the remote control connection reach the main thread's queue under.
//
pub const from_remote_control: u32 = 0xFFFF_FFF2;

//
// How long the frontend has to reply to a command, in milliseconds.
//
pub const answer_timeout_ms: u64 = 30_000;

//
// The number the main thread's messages reach the connection thread's queue under, and the connection thread's reach the queue
// the main thread waits on while it starts.
//
const from_main: u32 = 0;

//
// How long the connect and the WebSocket handshake each have, in milliseconds. The server runs on the test's own machine, so it
// answers at once unless it is gone.
//
const connect_timeout_ms: u32 = 10_000;

//
// How long the app has to stop after the quit command before the connection thread ends the process. The MacOS native app cannot
// quit while AppKit holds its main thread waiting on the system's open and save panel service, which on a CI runner has not
// answered at all; the quit, which goes to the main thread, then never runs. Quitting is a test's last word to the app, so it ends the
// process instead of leaving it running.
//
const quit_stop_seconds: i64 = 10;

//
// The longest remote control address taken, "host:port". A loopback address and a port are far shorter.
//
const address_length_max = 255;

//
// A single threaded Io of the calling thread's own.
//
fn ownIo(allocator: std.mem.Allocator) std.Io.Threaded {
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    return threaded;
}

//
// The main thread's side of the remote control connection of one core.
//
pub const RemoteControl = struct {
    // The connection thread's messages: "stop" from the main thread. Allocated, so its address stays the same however this struct is
    // moved.
    queue: *MessageQueue,
    // A copy of the connection's socket handle, which beginStop shuts down to end the connection thread's read. The connection thread
    // owns the socket and closes it.
    socket: std.Io.net.Socket.Handle,
    // The thread that owns the connection.
    thread: std.Thread,

    //
    // Starts the thread that connects to the remote control server at `config.remote_control` and waits for it to connect. A failed
    // connect is printed with the address and fails the start, so the app does not run without the connection the test is waiting
    // for. `io` is the main thread's.
    //
    pub fn start(allocator: std.mem.Allocator, io: std.Io, config: types.ZiggyConfig, native: NativeApp, main_queue: *MessageQueue) !RemoteControl {
        const address_text = std.mem.span(config.remote_control orelse @panic("the remote control connection was started without an address"));
        std.debug.assert(config.test_mode);
        if (address_text.len > address_length_max) {
            std.debug.print("ziggy remote control: the address given with --remote-control is longer than {d} characters: {s}\n", .{ address_length_max, address_text });
            return error.RemoteControlAddressTooLong;
        }
        var address: [address_length_max]u8 = undefined;
        @memcpy(address[0..address_text.len], address_text);

        const queue = try allocator.create(MessageQueue);
        errdefer allocator.destroy(queue);
        queue.* = MessageQueue.init();
        errdefer queue.deinit();

        // The connection thread tells this thread whether it connected, and this thread waits for that before it returns.
        var started = MessageQueue.init();
        defer started.deinit();
        const thread = try std.Thread.spawn(.{}, serveConnection, .{ConnectionStart{
            .address = address,
            .address_length = address_text.len,
            .native = .{
                .app = native,
                .has_quit = config.has_quit,
                .has_menu_action = config.has_menu_action,
                .has_screenshot = config.has_screenshot,
            },
            .main_queue = main_queue,
            .queue = queue,
            .started = &started,
        }});
        const report = started.take(io, allocator, .none) orelse {
            @panic("ziggy remote control: the queue the connection thread reports its start on closed");
        };
        defer allocator.free(report.text);
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const parsed = try std.json.parseFromSliceLeaky(StartReport, arena_state.allocator(), report.text, .{});
        const socket_number = parsed.socket orelse {
            thread.join();
            std.debug.print("ziggy remote control: could not connect to the remote control server at ws://{s}/: {s}\n", .{ address_text, parsed.@"error" orelse "unknown" });
            return error.RemoteControlConnectFailed;
        };
        return .{
            .queue = queue,
            .socket = socketHandle(socket_number),
            .thread = thread,
        };
    }

    //
    // Tells the connection thread to stop and ends its read by shutting the socket down. The main thread keeps replying to what the
    // connection sends it, each with ShuttingDown, until the connection thread sends it "remote-control-stopped", then calls
    // finishStop. `io` is the main thread's.
    //
    pub fn beginStop(self: *RemoteControl, io: std.Io) void {
        self.queue.post(io, from_main, "{\"type\":\"stop\"}") catch @panic("out of memory stopping the remote control connection");
        const stream: std.Io.net.Stream = .{
            .socket = .{
                .handle = self.socket,
                .address = .{
                    .ip4 = .unspecified(0),
                },
            },
        };
        stream.shutdown(io, .both) catch |err| switch (err) {
            // The server has ended the connection already, so the read has ended too.
            error.ConnectionAborted, error.ConnectionResetByPeer, error.SocketUnconnected => {},
            else => std.debug.panic("ziggy remote control: could not shut the connection down to stop it: {s}", .{@errorName(err)}),
        };
    }

    //
    // Waits for the connection thread to end and releases its queue, with the main thread's allocator, which `start` allocated it
    // with. Called once the connection thread has sent "remote-control-stopped".
    //
    pub fn finishStop(self: *RemoteControl, allocator: std.mem.Allocator) void {
        self.thread.join();
        self.queue.deinit();
        allocator.destroy(self.queue);
    }
};

//
// What the connection thread reports when it has tried to connect: the socket's handle as a number when it connected, or the error
// when it did not.
//
const StartReport = struct {
    socket: ?u64 = null,
    @"error": ?[]const u8 = null,
};

//
// The socket's handle as a number, which a message can carry. A handle is a file descriptor on Linux, macOS and Android and a pointer
// on Windows.
//
fn socketNumber(handle: std.Io.net.Socket.Handle) u64 {
    return switch (@typeInfo(std.Io.net.Socket.Handle)) {
        .pointer => @intFromPtr(handle),
        .int => @intCast(handle),
        else => @compileError("a socket handle is a file descriptor or a pointer"),
    };
}

//
// The socket's handle from the number socketNumber made of it.
//
fn socketHandle(number: u64) std.Io.net.Socket.Handle {
    return switch (@typeInfo(std.Io.net.Socket.Handle)) {
        .pointer => @ptrFromInt(number),
        .int => @intCast(number),
        else => @compileError("a socket handle is a file descriptor or a pointer"),
    };
}

//
// A remote control address, split.
//
pub const HostPort = struct {
    // The host, a name or an IP address.
    host: []const u8,
    // The port, never 0.
    port: u16,
};

//
// The host and port of a "host:port" address, or null when it is not one. The port is after the last colon.
//
pub fn splitAddress(address: []const u8) ?HostPort {
    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse {
        return null;
    };
    if (colon == 0) {
        return null;
    }
    const port = std.fmt.parseInt(u16, address[colon + 1 ..], 10) catch {
        return null;
    };
    if (port == 0) {
        return null;
    }
    return .{
        .host = address[0..colon],
        .port = port,
    };
}

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
// What the connection thread is given when it starts, which it owns from then on.
//
const ConnectionStart = struct {
    // The remote control server's address, "host:port", in the first address_length bytes.
    address: [address_length_max]u8,
    // How many bytes of address are the address.
    address_length: usize,
    // How the thread reaches the native app.
    native: NativeAccess,
    // The core's main thread's queue, where the commands that need the core go.
    main_queue: *MessageQueue,
    // The connection thread's messages: "stop" from the main thread.
    queue: *MessageQueue,
    // Where the thread reports whether it connected. The main thread waits on it in start and releases it once the report has come,
    // so the thread posts to it once and never touches it again.
    started: *MessageQueue,
};

//
// The connection thread: connects, reports whether it did, serves the connection's commands until the connection ends or the thread
// is sent "stop", then waits for "stop", closes the connection and tells the main thread it has stopped. The command being run
// finishes first.
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

    const address = given.address[0..given.address_length];
    var client = connect(io, allocator, address) catch |err| {
        const report = json.stringify(allocator, .{
            .@"error" = @errorName(err),
        }) catch @panic("out of memory reporting a failed remote control connection");
        defer allocator.free(report);
        given.started.post(io, from_main, report) catch @panic("out of memory reporting a failed remote control connection");
        return;
    };
    {
        const report = json.stringify(allocator, .{
            .socket = socketNumber(client.stream.stream.socket.handle),
        }) catch @panic("out of memory reporting the remote control connection");
        defer allocator.free(report);
        given.started.post(io, from_main, report) catch @panic("out of memory reporting the remote control connection");
    }

    var connection: Connection = .{
        .start = given,
        .replies = MessageQueue.init(),
    };
    defer connection.replies.deinit();
    // The socket is closed only once the main thread has said to stop, because until then it may still shut the socket down by its
    // handle.
    if (!connection.serve(io, allocator, &client)) {
        // After a quit, stopping the app sends "stop" here. When it does not come in time, the native app could not quit, and the
        // process is ended, loudly, with a failing exit status.
        const timeout: std.Io.Timeout = if (connection.quit_sent) .{
            .duration = .{
                .raw = .fromSeconds(quit_stop_seconds),
                .clock = .awake,
            },
        } else .none;
        const stop = given.queue.take(io, allocator, timeout) orelse {
            if (connection.quit_sent and !given.queue.isClosed(io)) {
                std.debug.print("ziggy remote control: the app had not stopped {d} seconds after the quit command, so the process is ended\n", .{quit_stop_seconds});
                std.process.exit(1);
            }
            @panic("ziggy remote control: the connection thread's queue closed before it was told to stop");
        };
        allocator.free(stop.text);
    }
    client.deinit();
    given.main_queue.post(io, from_remote_control, "{\"type\":\"remote-control-stopped\"}") catch @panic("out of memory stopping the remote control connection");
}

//
// Connects to the remote control server at the "host:port" address and makes the WebSocket handshake.
//
fn connect(io: std.Io, allocator: std.mem.Allocator, address: []const u8) !websocket.Client {
    const split = splitAddress(address) orelse {
        return error.RemoteControlAddressInvalid;
    };
    var client = try websocket.Client.init(io, allocator, .{
        .host = split.host,
        .port = split.port,
        .connect_timeout_ms = connect_timeout_ms,
    });
    errdefer client.deinit();
    var headers_buffer: [address_length_max + 16]u8 = undefined;
    const headers = try std.fmt.bufPrint(&headers_buffer, "Host: {s}", .{address});
    try client.handshake("/", .{
        .timeout_ms = connect_timeout_ms,
        .headers = headers,
    });
    return client;
}

//
// The connection thread's own state, on its stack. It keeps no Io or allocator: each function is given the thread's own.
//
const Connection = struct {
    // What the thread was given.
    start: ConnectionStart,
    // Where the main thread's replies come.
    replies: MessageQueue,
    // Whether the quit command was passed to the native app, after which the app has quit_stop_seconds to stop.
    quit_sent: bool = false,

    //
    // Reads commands and sends their replies until the connection ends or the thread is sent "stop". Returns whether it took
    // "stop".
    //
    fn serve(self: *Connection, io: std.Io, allocator: std.mem.Allocator, client: *websocket.Client) bool {
        while (true) {
            if (self.stopRequested(io, allocator)) {
                return true;
            }
            // Blocks until a message comes. On stop the main thread shuts the socket down, which ends the read with an error.
            const message = client.read() catch {
                return false;
            } orelse {
                continue;
            };
            defer client.done(message);
            switch (message.type) {
                .text => {},
                .binary => {
                    var refused = "{\"error\":\"InvalidCommand\"}".*;
                    client.write(&refused) catch {
                        return false;
                    };
                    continue;
                },
                .ping => {
                    client.writePong(message.data) catch {
                        return false;
                    };
                    continue;
                },
                .pong => {
                    continue;
                },
                .close => {
                    return false;
                },
            }
            var quit_after_reply = false;
            const reply = self.handleLine(io, allocator, message.data, &quit_after_reply) catch |err| blk: {
                const text = json.stringify(allocator, .{
                    .@"error" = @errorName(err),
                }) catch {
                    return false;
                };
                break :blk text;
            };
            defer allocator.free(reply);
            client.write(reply) catch {
                return false;
            };
            if (quit_after_reply) {
                // The app is asked to quit only once the reply has gone, so quitting, which stops the connection, cannot lose it.
                self.start.native.app.call(io, allocator, .quit, null) catch @panic("out of memory asking the native app to quit");
                self.quit_sent = true;
                // Nothing is read after a quit: the app is stopping, and stopping shuts the socket down.
                return false;
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
                try self.start.main_queue.post(io, from_remote_control, "{\"type\":\"test-ui-reloading\"}");
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
                @panic("ziggy remote control: a connection's queue closed while it waited for a screenshot");
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
        try self.start.main_queue.postReplyTo(io, from_remote_control, message, &self.replies);
        const reply = self.replies.take(io, allocator, .none) orelse {
            @panic("ziggy remote control: a connection's queue closed while it waited for the main thread");
        };
        return reply.text;
    }
};
