//
// A WebSocket server for the core's remote control tests, made with websocket.zig's server: the core connects to it as it connects
// to the remote control server, and a test sends it commands and reads the core's replies. The test's thread and the server's threads
// share nothing but message queues: a test posts each command to the `outgoing` queue, a sender thread of the connection takes it
// and writes it to the core, and every reply, connect and close the server sees is posted to the `events` queue for the test to take.
//

const std = @import("std");
const websocket = @import("websocket");
const ziggy = @import("ziggy");

const MessageQueue = ziggy.message_queue.MessageQueue;

//
// The numbers the server's events reach the `events` queue under.
//
const event_connected: u32 = 0;
const event_message: u32 = 1;
const event_closed: u32 = 2;

//
// The numbers the test's messages reach the `outgoing` queue under: a command to send, a request to close the connection, and the
// end of the connection, which ends the sender thread.
//
const outgoing_command: u32 = 0;
const outgoing_close: u32 = 1;
const outgoing_end: u32 = 2;

//
// How long a test waits for the core to connect or reply before it fails, in milliseconds. A reply that waits for the frontend has
// that long too, which is far longer than any of these tests takes.
//
const wait_ms: i64 = 10_000;

//
// What the server's handlers are given: the queues they share with the test.
//
const Context = struct {
    // What the server saw, for the test to take.
    events: MessageQueue,
    // What the test wants sent, for the connection's sender thread to take.
    outgoing: MessageQueue,
};

//
// One connection from the core. The server makes one per connection and calls it on its own threads.
//
const Handler = struct {
    // The connection, which the sender thread writes to.
    conn: *websocket.Conn,
    // The queues shared with the test.
    context: *Context,
    // The thread that writes the test's commands to the connection, once the handshake has been answered.
    sender: ?std.Thread,
    // Whether close has run. The server can call close from two threads at once, so it is atomic.
    closed: std.atomic.Value(bool),

    pub fn init(handshake: *websocket.Handshake, conn: *websocket.Conn, context: *Context) !Handler {
        _ = handshake;
        return .{
            .conn = conn,
            .context = context,
            .sender = null,
            .closed = .init(false),
        };
    }

    pub fn afterInit(self: *Handler) !void {
        self.sender = try std.Thread.spawn(.{}, send, .{ self.conn, &self.context.outgoing, &self.context.events });
        try self.context.events.post(std.testing.io, event_connected, "connected");
    }

    pub fn clientMessage(self: *Handler, data: []const u8) !void {
        try self.context.events.post(std.testing.io, event_message, data);
    }

    pub fn close(self: *Handler) void {
        // The server calls close from its worker's cleanup and from stop, and when the core has just closed the connection the two
        // can run at once for the same connection, so only the first does anything.
        if (self.closed.swap(true, .acq_rel)) {
            return;
        }
        if (self.sender) |sender| {
            self.context.outgoing.post(std.testing.io, outgoing_end, "end") catch @panic("out of memory ending the test server's sender");
            sender.join();
            self.sender = null;
        }
        self.context.events.post(std.testing.io, event_closed, "closed") catch @panic("out of memory reporting a closed connection");
    }
};

//
// The sender thread: writes each command the test posts to the connection, closes it and reports the close when asked, and ends
// with the connection.
//
fn send(conn: *websocket.Conn, outgoing: *MessageQueue, events: *MessageQueue) void {
    var thread_allocator: ziggy.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();
    while (true) {
        const message = outgoing.take(io, allocator, .none) orelse {
            return;
        };
        defer allocator.free(message.text);
        switch (message.from) {
            outgoing_command => conn.write(message.text) catch |err| {
                std.debug.panic("the test server could not send a command to the core: {s}", .{@errorName(err)});
            },
            outgoing_close => {
                conn.close(.{}) catch |err| {
                    std.debug.panic("the test server could not close the connection: {s}", .{@errorName(err)});
                };
                // The server does not call the handler's close for a connection it closed itself, so the close is reported here.
                events.post(io, event_closed, "closed") catch @panic("out of memory reporting a closed connection");
            },
            else => return,
        }
    }
}

//
// A running test server.
//
pub const RemoteControlServer = struct {
    // The websocket.zig server.
    server: websocket.Server(Handler),
    // The thread the server listens on.
    thread: std.Thread,
    // The queues shared with the server's handlers. Its address is given to the server, so the struct is never moved once started.
    context: Context,
    // The server's address, "127.0.0.1:<port>" with a terminating NUL, as the core's configuration takes it.
    address_buffer: [32]u8,
    // How many bytes of address_buffer are the address, not counting the NUL.
    address_length: usize,
    // How many connections have reported they opened and not yet that they closed, counted as the test takes the events.
    open_connections: i32,

    //
    // Starts the server on a free loopback port, in place.
    //
    pub fn start(self: *RemoteControlServer) !void {
        // websocket.zig's server does not report a port the system chose, so a free one is found first.
        const port = try freePort();
        const written = try std.fmt.bufPrintZ(&self.address_buffer, "127.0.0.1:{d}", .{port});
        self.address_length = written.len;
        self.open_connections = 0;
        self.context = .{
            .events = MessageQueue.init(),
            .outgoing = MessageQueue.init(),
        };
        self.server = try websocket.Server(Handler).init(std.testing.io, std.testing.allocator, .{
            .port = port,
            .address = "127.0.0.1",
            .handshake = .{
                .timeout = 3,
                .max_size = 1024,
                .max_headers = 0,
            },
        });
        self.thread = try self.server.listenInNewThread(&self.context);
    }

    //
    // Stops the server and releases it. websocket.zig's stop can return while a worker thread is still closing a connection the
    // core has just closed, so it first waits for every connection that is open to report its close.
    //
    pub fn stop(self: *RemoteControlServer) void {
        while (self.open_connections > 0) {
            const event = self.takeEvent(wait_ms) orelse {
                @panic("a connection to the test server was never closed");
            };
            std.testing.allocator.free(event.text);
        }
        self.server.stop();
        self.thread.join();
        self.server.deinit();
        self.context.events.deinit();
        self.context.outgoing.deinit();
    }

    //
    // The address to give the core as its configuration's remote_control.
    //
    pub fn address(self: *const RemoteControlServer) [*:0]const u8 {
        return @ptrCast(&self.address_buffer);
    }

    //
    // Sends a command to the connected core.
    //
    pub fn send(self: *RemoteControlServer, line: []const u8) !void {
        try self.context.outgoing.post(std.testing.io, outgoing_command, line);
    }

    //
    // Closes the core's connection from the server's side.
    //
    pub fn closeConnection(self: *RemoteControlServer) !void {
        try self.context.outgoing.post(std.testing.io, outgoing_close, "close");
    }

    //
    // Waits for the core to connect.
    //
    pub fn expectConnected(self: *RemoteControlServer) !void {
        const text = try self.expectEvent(event_connected);
        std.testing.allocator.free(text);
    }

    //
    // Waits for the core's connection to close.
    //
    pub fn expectClosed(self: *RemoteControlServer) !void {
        const text = try self.expectEvent(event_closed);
        std.testing.allocator.free(text);
    }

    //
    // Waits for the core's next reply and returns it, allocated with the testing allocator.
    //
    pub fn reply(self: *RemoteControlServer) ![]u8 {
        return try self.expectEvent(event_message);
    }

    //
    // Whether an event came within the time, which a test that expects none uses. A connect, a reply or a close all count.
    //
    pub fn hasEventWithin(self: *RemoteControlServer, milliseconds: i64) bool {
        const event = self.takeEvent(milliseconds) orelse {
            return false;
        };
        std.testing.allocator.free(event.text);
        return true;
    }

    //
    // Waits for the next event and fails unless it is of the kind given. Returns its text, allocated with the testing allocator.
    //
    fn expectEvent(self: *RemoteControlServer, kind: u32) ![]u8 {
        const event = self.takeEvent(wait_ms) orelse {
            return error.NoEventFromTheCore;
        };
        if (event.from != kind) {
            std.debug.print("the test server expected event {d} and saw {d}: {s}\n", .{ kind, event.from, event.text });
            std.testing.allocator.free(event.text);
            return error.UnexpectedEventFromTheCore;
        }
        return event.text;
    }

    //
    // Takes the next event, waiting until the time has passed, and counts the connections it opens and closes. Every event is taken
    // through here, so the count stays right.
    //
    fn takeEvent(self: *RemoteControlServer, milliseconds: i64) ?ziggy.message_queue.Message {
        const event = self.context.events.take(std.testing.io, std.testing.allocator, .{
            .duration = .{
                .raw = .fromMilliseconds(milliseconds),
                .clock = .awake,
            },
        }) orelse {
            return null;
        };
        switch (event.from) {
            event_connected => self.open_connections += 1,
            event_closed => self.open_connections -= 1,
            else => {},
        }
        return event;
    }
};

//
// A loopback port no socket is listening on now, which the system chose.
//
fn freePort() !u16 {
    const any = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try any.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    return listener.socket.address.getPort();
}
