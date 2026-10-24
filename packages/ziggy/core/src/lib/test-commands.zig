//
// The main thread's side of the test control connection (see test-control.zig): whether the frontend is listening, the commands
// waiting for it and what a test has set the next native dialog to return. It is a piece of the main thread's state, a variable of the
// main thread's function, and only the main thread uses it.
//

const std = @import("std");
const json = @import("json.zig");
const types = @import("types.zig");
const message_queue = @import("message-queue.zig");
const timers_lib = @import("timers.zig");
const test_control = @import("test-control.zig");
const dropped_files = @import("dropped-files.zig");
const Frontend = @import("core.zig").Frontend;

const MessageQueue = message_queue.MessageQueue;
const QueueMessage = message_queue.Message;
const TimerId = timers_lib.TimerId;
const Timers = timers_lib.Timers;

//
// A command the test control connection sent for the frontend, waiting to be forwarded.
//
const UiCommand = struct {
    // The command's JSON text, owned by the test commands.
    command_json: []u8,
    // Where the reply goes.
    reply_to: *MessageQueue,
    // The timer that gives up on the frontend when it has not reported it is listening in time.
    timer: TimerId,
};

//
// A command that waits for the frontend to report it is listening.
//
const UiWait = struct {
    // Where the reply goes.
    reply_to: *MessageQueue,
    // The timer that gives up on the frontend when it has not reported it is listening in time.
    timer: TimerId,
};

//
// The command forwarded to the frontend that has no result yet.
//
const OutstandingCommand = struct {
    // The number the test-command event carried, which the frontend's test-result names.
    request_id: u64,
    // Where the reply goes.
    reply_to: *MessageQueue,
    // The timer that gives up on the frontend when it sends no result in time.
    timer: TimerId,
};

//
// The main thread's side of the test control connection. It keeps no Io, allocator or timers: each function is given the main
// thread's, and what it keeps is allocated with the main thread's allocator.
//
pub const TestCommands = struct {
    // Sends the commands to the frontend.
    frontend: Frontend,
    // The test control connection, only in a test hooks build and only when the native app is in test mode.
    connection: ?test_control.TestControl,
    // Whether the frontend has reported it is listening for test commands.
    ui_ready: bool,
    // The commands waiting to be forwarded to the frontend, in the order they came.
    commands: std.ArrayList(UiCommand),
    // The commands waiting for the frontend to report it is listening.
    waits: std.ArrayList(UiWait),
    // The command with the frontend, which only ever has one at a time.
    outstanding: ?OutstandingCommand,
    // The number of the next command forwarded.
    next_request: u64,
    // What a test has set the next native dialog to return, as the JSON text of an array of paths, until a dialog takes it.
    pick_result: ?[]u8,

    //
    // Makes the test commands, with no connection yet.
    //
    pub fn init(frontend: Frontend) TestCommands {
        return .{
            .frontend = frontend,
            .connection = null,
            .ui_ready = false,
            .commands = .empty,
            .waits = .empty,
            .outstanding = null,
            .next_request = 1,
            .pick_result = null,
        };
    }

    //
    // Releases the commands, once the connection has stopped.
    //
    pub fn deinit(self: *TestCommands, allocator: std.mem.Allocator) void {
        for (self.commands.items) |command| {
            allocator.free(command.command_json);
        }
        self.commands.deinit(allocator);
        self.waits.deinit(allocator);
        if (self.pick_result) |text| {
            allocator.free(text);
        }
    }

    //
    // Takes what a test has set the next native dialog to return, or null when it has set nothing. The caller frees it with the
    // main thread's allocator.
    //
    pub fn takePickResult(self: *TestCommands) ?[]u8 {
        const picked = self.pick_result orelse {
            return null;
        };
        self.pick_result = null;
        return picked;
    }

    //
    // Handles a message from the test control connection, which always gets a reply. A test's drop is recorded in `dropped`.
    //
    pub fn handleMessage(self: *TestCommands, io: std.Io, allocator: std.mem.Allocator, timers: Timers, dropped: *dropped_files.DroppedFiles, message: QueueMessage) void {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, message.text, .{}) catch {
            std.debug.panic("the test control connection sent a message that is not JSON: {s}", .{message.text});
        };
        const message_type = json.getString(parsed, "type") orelse "";
        if (std.mem.eql(u8, message_type, "test-ui-reloading")) {
            self.ui_ready = false;
            return;
        }
        const reply_to = message.reply_to orelse {
            std.debug.panic("the test control connection sent a message with nowhere to reply: {s}", .{message.text});
        };
        if (std.mem.eql(u8, message_type, "test-wait-ui")) {
            if (self.ui_ready) {
                reply(io, reply_to, "{\"ok\":true}");
                return;
            }
            const timer = timers.setTimeout(io, .{
                .context = self,
                .function = uiWaitTimedOut,
            }, test_control.answer_timeout_ms) catch @panic("out of memory waiting for the frontend");
            self.waits.append(allocator, .{
                .reply_to = reply_to,
                .timer = timer,
            }) catch @panic("out of memory waiting for the frontend");
            return;
        }
        if (std.mem.eql(u8, message_type, "test-ui-command")) {
            const command = parsed.object.get("command") orelse .null;
            const command_json = json.stringify(allocator, command) catch @panic("out of memory forwarding a test command");
            const timer = timers.setTimeout(io, .{
                .context = self,
                .function = uiWaitTimedOut,
            }, test_control.answer_timeout_ms) catch @panic("out of memory forwarding a test command");
            self.commands.append(allocator, .{
                .command_json = command_json,
                .reply_to = reply_to,
                .timer = timer,
            }) catch @panic("out of memory forwarding a test command");
            self.forwardNext(io, allocator, timers);
            return;
        }
        if (std.mem.eql(u8, message_type, "test-drop")) {
            const files = parsed.object.get("files") orelse .null;
            const files_json = json.stringify(arena, files) catch @panic("out of memory recording a drop");
            dropped.record(allocator, files_json) catch |err| {
                reply(io, reply_to, json.stringify(arena, .{
                    .@"error" = @errorName(err),
                }) catch @panic("out of memory replying to the test control connection"));
                return;
            };
            reply(io, reply_to, "{\"ok\":true}");
            return;
        }
        if (std.mem.eql(u8, message_type, "test-pick-answer")) {
            const paths = parsed.object.get("paths") orelse .null;
            const picked = json.stringify(allocator, paths) catch @panic("out of memory keeping what a dialog returns");
            if (self.pick_result) |old| {
                allocator.free(old);
            }
            self.pick_result = picked;
            reply(io, reply_to, "{\"ok\":true}");
            return;
        }
        std.debug.panic("the test control connection sent a message of an unknown type: {s}", .{message.text});
    }

    //
    // The frontend has reported it is listening for test commands (test-ui-ready): replies to the commands waiting for it and forwards
    // the next command. Fails with TestControlNotRunning when there is no test control connection.
    //
    pub fn uiReady(self: *TestCommands, io: std.Io, allocator: std.mem.Allocator, timers: Timers) !void {
        if (self.connection == null) {
            return error.TestControlNotRunning;
        }
        self.ui_ready = true;
        for (self.waits.items) |wait| {
            timers.clearTimeout(wait.timer);
            reply(io, wait.reply_to, "{\"ok\":true}");
        }
        self.waits.clearRetainingCapacity();
        self.forwardNext(io, allocator, timers);
    }

    //
    // The frontend has sent the result of a test command (test-result): sends its result, JSON text, to the connection waiting for it and
    // forwards the next command. Fails with TestControlNotRunning when there is no test control connection, and with
    // UnexpectedTestResult when no command of that number is with the frontend.
    //
    pub fn result(self: *TestCommands, io: std.Io, allocator: std.mem.Allocator, timers: Timers, request_id: u64, result_json: []const u8) !void {
        if (self.connection == null) {
            return error.TestControlNotRunning;
        }
        const outstanding = self.outstanding orelse {
            return error.UnexpectedTestResult;
        };
        if (outstanding.request_id != request_id) {
            return error.UnexpectedTestResult;
        }
        self.outstanding = null;
        timers.clearTimeout(outstanding.timer);
        try outstanding.reply_to.post(io, 0, result_json);
        self.forwardNext(io, allocator, timers);
    }

    //
    // Replies to every command the test control connection is waiting on with ShuttingDown, so its connections stop waiting for the main
    // thread before they are ended.
    //
    pub fn refuseWhileStopping(self: *TestCommands, io: std.Io, allocator: std.mem.Allocator) void {
        const shutting_down = "{\"error\":\"ShuttingDown\"}";
        if (self.outstanding) |outstanding| {
            reply(io, outstanding.reply_to, shutting_down);
            self.outstanding = null;
        }
        for (self.commands.items) |command| {
            reply(io, command.reply_to, shutting_down);
            allocator.free(command.command_json);
        }
        self.commands.clearRetainingCapacity();
        for (self.waits.items) |wait| {
            reply(io, wait.reply_to, shutting_down);
        }
        self.waits.clearRetainingCapacity();
    }

    //
    // Stops the test control connection, when there is one: tells it to stop, reads the main thread's queue, replying to whatever its
    // connections send meanwhile with ShuttingDown until it reports it has stopped, and waits for its threads to end. Every other message
    // read meanwhile is dropped.
    //
    pub fn stop(self: *TestCommands, io: std.Io, allocator: std.mem.Allocator, queue: *MessageQueue) void {
        if (self.connection == null) {
            return;
        }
        const connection = &self.connection.?;
        connection.beginStop(io);
        while (true) {
            const message = queue.take(io, allocator, .none) orelse {
                break;
            };
            defer allocator.free(message.text);
            if (message.from != test_control.from_test_control) {
                continue;
            }
            if (message.reply_to) |reply_to| {
                reply(io, reply_to, "{\"error\":\"ShuttingDown\"}");
                continue;
            }
            if (std.mem.indexOf(u8, message.text, "\"test-control-stopped\"") != null) {
                break;
            }
        }
        connection.finishStop(allocator);
        self.connection = null;
    }

    //
    // Refuses a message the test control connection sent while the main thread stops, with ShuttingDown, so the connection stops
    // waiting. A message from anyone else, or one that wants no reply, changes nothing.
    //
    pub fn refuse(io: std.Io, message: QueueMessage) void {
        if (message.from != test_control.from_test_control) {
            return;
        }
        if (message.reply_to) |reply_to| {
            reply(io, reply_to, "{\"error\":\"ShuttingDown\"}");
        }
    }

    //
    // Posts a reply to a connection.
    //
    fn reply(io: std.Io, reply_to: *MessageQueue, text: []const u8) void {
        reply_to.post(io, 0, text) catch @panic("out of memory replying to the test control connection");
    }

    //
    // Forwards the next test command to the frontend, when the frontend is listening and has no other command.
    //
    fn forwardNext(self: *TestCommands, io: std.Io, allocator: std.mem.Allocator, timers: Timers) void {
        if (!self.ui_ready or self.outstanding != null or self.commands.items.len == 0) {
            return;
        }
        const command = self.commands.orderedRemove(0);
        defer allocator.free(command.command_json);
        timers.clearTimeout(command.timer);
        const request_id = self.next_request;
        self.next_request += 1;
        const timer = timers.setTimeout(io, .{
            .context = self,
            .function = commandTimedOut,
        }, test_control.answer_timeout_ms) catch @panic("out of memory forwarding a test command");
        self.outstanding = .{
            .request_id = request_id,
            .reply_to = command.reply_to,
            .timer = timer,
        };
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const event = json.stringify(arena_state.allocator(), .{
            .kind = "system",
            .name = "test-command",
            .data = .{
                .requestId = request_id,
                .command = json.Raw{
                    .text = command.command_json,
                },
            },
        }) catch @panic("out of memory forwarding a test command");
        self.frontend.deliver(io, event);
    }

    //
    // A command waited longer than the frontend has to report it is listening: replies to every command and wait whose time is up with
    // UiDidNotAnswer.
    //
    fn uiWaitTimedOut(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, services: ?*const anyopaque) void {
        _ = services;
        const self: *TestCommands = @ptrCast(@alignCast(context.?));
        const timed_out = "{\"error\":\"UiDidNotAnswer\"}";
        var index: usize = 0;
        while (index < self.waits.items.len) {
            const wait = self.waits.items[index];
            if (timers.isSet(wait.timer)) {
                index += 1;
                continue;
            }
            reply(io, wait.reply_to, timed_out);
            _ = self.waits.orderedRemove(index);
        }
        index = 0;
        while (index < self.commands.items.len) {
            const command = self.commands.items[index];
            if (timers.isSet(command.timer)) {
                index += 1;
                continue;
            }
            reply(io, command.reply_to, timed_out);
            allocator.free(command.command_json);
            _ = self.commands.orderedRemove(index);
        }
    }

    //
    // The frontend sent no result for the command in time: replies with UiDidNotAnswer and forwards the next one.
    //
    fn commandTimedOut(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, services: ?*const anyopaque) void {
        _ = services;
        const self: *TestCommands = @ptrCast(@alignCast(context.?));
        const outstanding = self.outstanding orelse {
            return;
        };
        self.outstanding = null;
        reply(io, outstanding.reply_to, "{\"error\":\"UiDidNotAnswer\"}");
        self.forwardNext(io, allocator, timers);
    }
};
