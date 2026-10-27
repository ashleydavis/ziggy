//
// A fake native app, for the unit tests of an app built on Ziggy. Nothing in a shipped app uses it, so it is never compiled into one.
//
// It does what a native app does on a thread of its own, its fake UI thread: it creates and destroys the core there, takes every
// message the core sends the native app (see native-message.zig), records the messages for the frontend and the calls, and gives the
// results of the calls that have one. The test's thread shares nothing with it: it reads what was recorded, and changes the result a
// call is given, by posting a request to the native app's queue and waiting for the reply on a queue of its own. The test's thread
// passes messages from the frontend to the core itself, as the native app's UI thread does. Every function is given the test thread's
// Io and allocator.
//

const std = @import("std");
const types = @import("types.zig");
const json = @import("json.zig");
const core = @import("core.zig");
const native_message = @import("native-message.zig");
const NativeSide = @import("native-side.zig").NativeSide;
const ThreadAllocator = @import("thread-allocator.zig").ThreadAllocator;
const worker_lib = @import("worker.zig");
const process_env = @import("task-queue.zig").utils.process_env;

const MessageQueue = core.MessageQueue;

//
// The kind of a request from the test's thread to the fake UI thread, which the core never sends.
//
const request_kind: u32 = 2;

//
// A fake native app.
//
pub const FakeNativeApp = struct {
    // The core's main thread's queue, which the fake UI thread gives the core and the test's thread posts the frontend's messages to.
    queue: MessageQueue,
    // The native app's queue, which the core's threads post to and the test's thread posts its requests to. Only the fake UI thread
    // takes from it.
    native_queue: MessageQueue,
    // Where the fake UI thread's replies to the test's thread come.
    replies: MessageQueue,
    // The fake UI thread, or null when no core runs.
    ui_thread: ?std.Thread,
    // Numbers the messages `handled` sends, so each one's reply is told apart.
    next_sync: u64,
    // The data directory `config` gives the core: a directory of the test's own under the test cache, so two tests running at once
    // never share one. Removed by deinit.
    data_tmp: std.testing.TmpDir,
    // The path of `data_tmp`, which `config` points the core at.
    data_dir_path: [128:0]u8,

    pub fn init(self: *FakeNativeApp) void {
        self.* = .{
            .queue = MessageQueue.init(),
            .native_queue = MessageQueue.init(),
            .replies = MessageQueue.init(),
            .ui_thread = null,
            .next_sync = 0,
            .data_tmp = std.testing.tmpDir(.{}),
            .data_dir_path = undefined,
        };
        _ = std.fmt.bufPrintZ(&self.data_dir_path, ".zig-cache/tmp/{s}", .{&self.data_tmp.sub_path}) catch unreachable;
    }

    pub fn deinit(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator) void {
        self.endUiThread(io, allocator);
        self.replies.deinit();
        self.native_queue.deinit();
        self.queue.deinit();
        self.data_tmp.cleanup();
    }

    //
    // Ends the fake UI thread, when there is one, and forgets what it recorded. Its core must have been stopped.
    //
    fn endUiThread(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator) void {
        const thread = self.ui_thread orelse {
            return;
        };
        const reply = self.request(io, allocator, .{
            .request = "end",
        }) catch @panic("out of memory ending the fake native app");
        allocator.free(reply);
        thread.join();
        self.ui_thread = null;
    }

    //
    // Starts a fake UI thread, which starts a core serving the app with the configuration, as a native app's ziggy_create does. A fake
    // UI thread of a core started before is ended first, and what it recorded is forgotten. Fails with the error the core's start failed
    // with.
    //
    pub fn start(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator, given_config: types.ZiggyConfig, app: core.RegisteredApp) !void {
        self.endUiThread(io, allocator);
        // The configuration's strings are valid only during this call, so the fake UI thread is sent copies of them.
        var copied = given_config;
        copied.app_url_prefix = "";
        copied.data_dir = "";
        copied.test_port_file = null;
        copied.arg_count = 0;
        copied.args = null;
        self.ui_thread = try std.Thread.spawn(.{}, runUiThread, .{ &self.queue, &self.native_queue, copied, app });
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        // The core's threads get the environment of the thread that creates the core, which is the fake UI thread, so it is sent a copy
        // of the test thread's.
        const environment: ?std.json.Value = if (process_env.getEnvironMap()) |map| try worker_lib.environmentJson(arena_state.allocator(), map) else null;
        const reply = try self.request(io, allocator, .{
            .request = "start",
            .appUrlPrefix = std.mem.span(given_config.app_url_prefix),
            .dataDir = std.mem.span(given_config.data_dir),
            .testPortFile = if (given_config.test_port_file) |path| std.mem.span(path) else null,
            .arguments = try types.configArguments(arena_state.allocator(), given_config),
            .environment = environment,
        });
        defer allocator.free(reply);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), reply, .{});
        if (json.getInteger(parsed, "error")) |error_number| {
            return @errorFromInt(@as(std.meta.Int(.unsigned, @bitSizeOf(anyerror)), @intCast(error_number)));
        }
    }

    //
    // Has the fake UI thread stop the core, as a native app's ziggy_destroy does, and waits for it. The fake UI thread keeps what it
    // recorded, the messages delivered while the core stopped too, until deinit.
    //
    pub fn stop(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator) void {
        const reply = self.request(io, allocator, .{
            .request = "stop",
        }) catch @panic("out of memory stopping the fake native app");
        allocator.free(reply);
    }

    //
    // Passes a message from the frontend to the core and returns at once, as a native app's ziggy_send_message does.
    //
    pub fn sendMessage(self: *FakeNativeApp, allocator: std.mem.Allocator, message: []const u8) void {
        core.sendMessage(allocator, &self.queue, message);
    }

    //
    // Records a drop on the window, as a native app's ziggy_files_dropped does.
    //
    pub fn filesDropped(self: *FakeNativeApp, allocator: std.mem.Allocator, paths_json: []const u8) !void {
        try core.filesDropped(allocator, &self.queue, paths_json);
    }

    //
    // The query of the frontend's address, as a native app's ziggy_ui_query gives it, allocated with the allocator, which the caller
    // frees it with.
    //
    pub fn uiQuery(self: *FakeNativeApp, allocator: std.mem.Allocator) ![:0]u8 {
        return try core.uiQuery(allocator, &self.queue);
    }

    //
    // The configuration to give a core: every call the native app can be made is given its result by the fake UI thread.
    //
    pub fn config(self: *FakeNativeApp, worker_threads: u32, max_children: u32) types.ZiggyConfig {
        return .{
            .wake_data = null,
            .wake = wake,
            .has_os_version = true,
            .has_quit = true,
            .has_pick_paths = true,
            .has_menu_action = true,
            .has_keep_alive = true,
            .has_native_call = true,
            .has_screenshot = true,
            .worker_threads = worker_threads,
            .max_concurrent_child_tasks = max_children,
            .app_url_prefix = "file:///app/dist/",
            .data_dir = &self.data_dir_path,
            .test_mode = false,
            .test_port_file = null,
            .arg_count = 0,
            .args = null,
        };
    }

    //
    // Has the fake UI thread give every call of the type ("os-version", "pick-paths", "native-call" or "screenshot") the text as its
    // result from now on: as the result when `succeeded`, and as the reason it failed otherwise.
    //
    pub fn setResult(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator, call_type: []const u8, succeeded: bool, text: []const u8) void {
        const reply = self.request(io, allocator, .{
            .request = "set-result",
            .type = call_type,
            .succeeded = succeeded,
            .text = text,
        }) catch @panic("out of memory changing a result of the fake native app");
        allocator.free(reply);
    }

    //
    // The number of messages delivered so far.
    //
    pub fn count(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator) usize {
        return self.requestNumber(io, allocator, .{
            .request = "count",
        });
    }

    //
    // The message at the index, allocated with the allocator.
    //
    pub fn messageAt(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator, index: usize) ![]u8 {
        return try self.request(io, allocator, .{
            .request = "message-at",
            .index = index,
        });
    }

    //
    // The number of delivered messages that contain the text.
    //
    pub fn countContaining(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator, text: []const u8) usize {
        return self.requestNumber(io, allocator, .{
            .request = "count-containing",
            .text = text,
        });
    }

    //
    // The index of the first message that contains the text, or null.
    //
    pub fn indexOfContaining(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator, text: []const u8) ?usize {
        const index = self.requestNumber(io, allocator, .{
            .request = "index-of-containing",
            .text = text,
        });
        return if (index == std.math.maxInt(usize)) null else index;
    }

    //
    // Forgets every delivered message that contains the text, for a test that sent a message of its own to see the core is done.
    //
    pub fn removeContaining(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator, text: []const u8) void {
        _ = self.requestNumber(io, allocator, .{
            .request = "remove-containing",
            .text = text,
        });
    }

    //
    // The menu actions the native app was called to do so far, one per line, allocated with the allocator.
    //
    pub fn chosenActions(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator) ![]u8 {
        return try self.request(io, allocator, .{
            .request = "chosen-actions",
        });
    }

    //
    // The paths the native app was called to write a screenshot to so far, one per line, allocated with the allocator.
    //
    pub fn screenshotPaths(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator) ![]u8 {
        return try self.request(io, allocator, .{
            .request = "screenshot-paths",
        });
    }

    //
    // What the native app was told by its keep-alive calls so far, in order, as the JSON text of an array of booleans, allocated with
    // the allocator.
    //
    pub fn keepAliveCalls(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator) ![]u8 {
        return try self.request(io, allocator, .{
            .request = "keep-alive-calls",
        });
    }

    //
    // Whether the native app has been called to quit.
    //
    pub fn quitCalled(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator) bool {
        return self.requestNumber(io, allocator, .{
            .request = "quit-called",
        }) != 0;
    }

    //
    // The JSON text of the last call of the type ("pick-paths", "native-call", ...) the native app was made, or null when there has
    // been none, allocated with the allocator.
    //
    pub fn lastCall(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator, call_type: []const u8) !?[]u8 {
        const reply = try self.request(io, allocator, .{
            .request = "last-call",
            .type = call_type,
        });
        if (reply.len == 0) {
            allocator.free(reply);
            return null;
        }
        return reply;
    }

    //
    // Waits until a message containing the text has been delivered, and fails the test when it takes too long.
    //
    pub fn expectMessageContaining(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator, text: []const u8) !void {
        var waited_ms: u32 = 0;
        while (waited_ms < 20_000) : (waited_ms += 2) {
            if (self.countContaining(io, allocator, text) > 0) {
                return;
            }
            sleepMs(io, 2);
        }
        std.debug.print("no message containing {s}\n", .{text});
        return error.MessageNeverArrived;
    }

    //
    // Waits until the native app has been asked to quit, and fails the test when it takes too long. Test control asks only after it
    // has written its reply to the quit command, so a test that has read the reply cannot check quitCalled straight away: the
    // Android unit tests (CI run on commit 024a4c8) failed "the quit command calls the native app's quit callback" doing that.
    //
    pub fn expectQuitCalled(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator) !void {
        var waited_ms: u32 = 0;
        while (waited_ms < 20_000) : (waited_ms += 2) {
            if (self.quitCalled(io, allocator)) {
                return;
            }
            sleepMs(io, 2);
        }
        std.debug.print("the native app was never asked to quit\n", .{});
        return error.QuitNeverCalled;
    }

    //
    // Passes a message from the frontend to the core, as a native app does, and waits until the core's main thread has handled it.
    //
    pub fn send(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator, message: []const u8) !void {
        self.sendMessage(allocator, message);
        try self.handled(io, allocator);
    }

    //
    // Waits until the core's main thread has handled every message sent to it so far. It sends a get-platform message of its own,
    // which the main thread handles after them, waits for its reply and takes the reply out of what this fake native app recorded.
    //
    pub fn handled(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator) !void {
        self.next_sync += 1;
        var buffer: [128]u8 = undefined;
        const marker = try std.fmt.bufPrint(&buffer, "\"ziggy-fake-native-app-sync-{d}\"", .{self.next_sync});
        var message_buffer: [256]u8 = undefined;
        self.sendMessage(allocator, try std.fmt.bufPrint(&message_buffer, "{{\"kind\":\"system\",\"id\":{s},\"name\":\"get-platform\"}}", .{marker}));
        try self.expectMessageContaining(io, allocator, marker);
        self.removeContaining(io, allocator, marker);
    }

    //
    // Sends the fake UI thread a request, the JSON text of the value, and waits for its reply, which is returned allocated with the
    // allocator.
    //
    fn request(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator, value: anytype) ![]u8 {
        const text = try json.stringify(allocator, value);
        defer allocator.free(text);
        try self.native_queue.postReplyTo(io, request_kind, text, &self.replies);
        const reply = self.replies.take(io, allocator, .none) orelse {
            @panic("the fake native app's reply queue closed");
        };
        return reply.text;
    }

    //
    // Sends the fake UI thread a request whose reply is a number, and returns the number.
    //
    fn requestNumber(self: *FakeNativeApp, io: std.Io, allocator: std.mem.Allocator, value: anytype) usize {
        const reply = self.request(io, allocator, value) catch @panic("out of memory sending the fake native app a request");
        defer allocator.free(reply);
        return std.fmt.parseInt(usize, reply, 10) catch {
            std.debug.panic("the fake native app replied with something that is not a number: {s}", .{reply});
        };
    }
};

//
// Sleeps, for tests that need time to pass.
//
pub fn sleepMs(io: std.Io, milliseconds: i64) void {
    io.sleep(.fromMilliseconds(milliseconds), .awake) catch @panic("sleep cancelled");
}

//
// What the fake native app's wake does: nothing, because its UI thread waits on the native app's queue.
//
fn wake(wake_data: ?*anyopaque) callconv(.c) void {
    _ = wake_data;
}

//
// A request from the test's thread, as it is written.
//
const Request = struct {
    request: []const u8,
    appUrlPrefix: ?[]const u8 = null,
    dataDir: ?[]const u8 = null,
    testPortFile: ?[]const u8 = null,
    arguments: ?[]const []const u8 = null,
    environment: ?std.json.Value = null,
    type: ?[]const u8 = null,
    succeeded: ?bool = null,
    text: ?[]const u8 = null,
    index: ?usize = null,
};

//
// The result a call of one type is given, when a test has set one.
//
const CallResult = struct {
    // Whether the call succeeds.
    succeeded: bool,
    // The result, or the reason.
    text: []u8,
};

//
// What the fake UI thread keeps: everything it recorded and the results the test set. Only the fake UI thread touches it, and it is
// allocated with the fake UI thread's allocator, which each function that allocates is given.
//
const Recorded = struct {
    // Every message delivered, in the order delivered.
    messages: std.ArrayList([]u8),
    // The menu actions chosen, one per line.
    chosen_actions: std.ArrayList(u8),
    // The paths screenshots were called for, one per line.
    screenshot_paths: std.ArrayList(u8),
    // The value of each keep-alive call, in order.
    keep_alive_calls: std.ArrayList(bool),
    // Whether a quit call came.
    quit_called: bool,
    // The last call of each type, by type.
    last_calls: std.StringHashMapUnmanaged([]u8),
    // The results the test set, by call type.
    results: std.StringHashMapUnmanaged(CallResult),

    const empty: Recorded = .{
        .messages = .empty,
        .chosen_actions = .empty,
        .screenshot_paths = .empty,
        .keep_alive_calls = .empty,
        .quit_called = false,
        .last_calls = .empty,
        .results = .empty,
    };

    fn deinit(self: *Recorded, allocator: std.mem.Allocator) void {
        for (self.messages.items) |message| {
            allocator.free(message);
        }
        self.messages.deinit(allocator);
        self.chosen_actions.deinit(allocator);
        self.screenshot_paths.deinit(allocator);
        self.keep_alive_calls.deinit(allocator);
        var calls = self.last_calls.iterator();
        while (calls.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.last_calls.deinit(allocator);
        var results = self.results.iterator();
        while (results.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.text);
        }
        self.results.deinit(allocator);
    }

    //
    // Records a message delivered to the frontend.
    //
    fn recordDelivered(context: *anyopaque, allocator: std.mem.Allocator, text: []const u8) void {
        const self: *Recorded = @ptrCast(@alignCast(context));
        const copy = allocator.dupe(u8, text) catch @panic("out of memory recording a message");
        self.messages.append(allocator, copy) catch @panic("out of memory recording a message");
    }

    //
    // Keeps the call's text as the last call of its type.
    //
    fn recordCall(self: *Recorded, allocator: std.mem.Allocator, call_type: []const u8, text: []const u8) !void {
        const copy = try allocator.dupe(u8, text);
        errdefer allocator.free(copy);
        if (self.last_calls.getPtr(call_type)) |last| {
            allocator.free(last.*);
            last.* = copy;
            return;
        }
        const key = try allocator.dupe(u8, call_type);
        errdefer allocator.free(key);
        try self.last_calls.put(allocator, key, copy);
    }

    //
    // Sets the result of every call of the type.
    //
    fn setResult(self: *Recorded, allocator: std.mem.Allocator, call_type: []const u8, succeeded: bool, text: []const u8) !void {
        const copy = try allocator.dupe(u8, text);
        errdefer allocator.free(copy);
        if (self.results.getPtr(call_type)) |given| {
            allocator.free(given.text);
            given.* = .{
                .succeeded = succeeded,
                .text = copy,
            };
            return;
        }
        const key = try allocator.dupe(u8, call_type);
        errdefer allocator.free(key);
        try self.results.put(allocator, key, .{
            .succeeded = succeeded,
            .text = copy,
        });
    }
};

//
// The fake UI thread: starts the core when the test sends it "start", then takes every message on the native app's queue, recording
// the messages, giving the calls their results and replying to the test's requests, until the test sends it "end".
//
fn runUiThread(main_queue: *MessageQueue, native_queue: *MessageQueue, given_config: types.ZiggyConfig, app: core.RegisteredApp) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();
    var native: NativeSide = .init(native_queue);
    defer native.deinit(allocator);
    var recorded: Recorded = .empty;
    defer recorded.deinit(allocator);
    var main_thread: ?std.Thread = null;
    while (true) {
        const taken = native.take(io, allocator, .none) orelse {
            @panic("the fake native app's queue closed");
        };
        switch (taken.kind) {
            .deliver => Recorded.recordDelivered(&recorded, allocator, taken.text),
            .call => handleCall(io, allocator, &native, &recorded, taken.text, taken.reply),
            _ => {
                var arena_state = std.heap.ArenaAllocator.init(allocator);
                defer arena_state.deinit();
                const arena = arena_state.allocator();
                const request = std.json.parseFromSliceLeaky(Request, arena, taken.text, .{}) catch {
                    std.debug.panic("the fake native app was sent a request it cannot read: {s}", .{taken.text});
                };
                const reply_to = taken.reply_to orelse {
                    std.debug.panic("the fake native app was sent a request with nowhere to reply: {s}", .{taken.text});
                };
                if (std.mem.eql(u8, request.request, "start")) {
                    var config = given_config;
                    config.app_url_prefix = (arena.dupeZ(u8, request.appUrlPrefix.?) catch @panic("out of memory starting the core")).ptr;
                    config.data_dir = (arena.dupeZ(u8, request.dataDir.?) catch @panic("out of memory starting the core")).ptr;
                    config.test_port_file = if (request.testPortFile) |path| (arena.dupeZ(u8, path) catch @panic("out of memory starting the core")).ptr else null;
                    const arguments = request.arguments orelse &.{};
                    const argument_pointers = arena.alloc([*:0]const u8, arguments.len) catch @panic("out of memory starting the core");
                    for (arguments, argument_pointers) |argument, *pointer| {
                        pointer.* = (arena.dupeZ(u8, argument) catch @panic("out of memory starting the core")).ptr;
                    }
                    config.arg_count = @intCast(arguments.len);
                    config.args = if (arguments.len > 0) argument_pointers.ptr else null;
                    // The test thread's environment is this thread's while it creates the core, which copies it.
                    var environment: ?std.process.Environ.Map = if (request.environment) |value| worker_lib.environmentFromJson(arena, value) catch @panic("out of memory starting the core") else null;
                    process_env.setEnvironMap(if (environment) |*map| map else null);
                    defer process_env.setEnvironMap(null);
                    main_thread = core.start(allocator, main_queue, native_queue, config, app) catch |err| {
                        var buffer: [64]u8 = undefined;
                        const failure = std.fmt.bufPrint(&buffer, "{{\"error\":{d}}}", .{@intFromError(err)}) catch unreachable;
                        reply_to.post(io, 0, failure) catch @panic("out of memory replying to the test");
                        continue;
                    };
                    reply_to.post(io, 0, "{}") catch @panic("out of memory replying to the test");
                    continue;
                }
                if (std.mem.eql(u8, request.request, "stop")) {
                    core.stop(allocator, main_queue, &native, .{
                        .context = &recorded,
                        .deliver = Recorded.recordDelivered,
                    }, main_thread.?);
                    main_thread = null;
                    reply_to.post(io, 0, "{}") catch @panic("out of memory replying to the test");
                    continue;
                }
                if (std.mem.eql(u8, request.request, "end")) {
                    reply_to.post(io, 0, "{}") catch @panic("out of memory replying to the test");
                    return;
                }
                const reply = replyTo(allocator, arena, &recorded, request) catch @panic("out of memory replying to the test");
                reply_to.post(io, 0, reply) catch @panic("out of memory replying to the test");
            },
        }
    }
}

//
// The reply to a request from the test's thread about what was recorded, allocated with the arena. The allocator is the fake UI
// thread's, which what was recorded is allocated with.
//
fn replyTo(allocator: std.mem.Allocator, arena: std.mem.Allocator, recorded: *Recorded, request: Request) ![]const u8 {
    const name = request.request;
    if (std.mem.eql(u8, name, "set-result")) {
        try recorded.setResult(allocator, request.type.?, request.succeeded.?, request.text.?);
        return "";
    }
    if (std.mem.eql(u8, name, "count")) {
        return try std.fmt.allocPrint(arena, "{d}", .{recorded.messages.items.len});
    }
    if (std.mem.eql(u8, name, "message-at")) {
        return recorded.messages.items[request.index.?];
    }
    if (std.mem.eql(u8, name, "count-containing")) {
        var found: usize = 0;
        for (recorded.messages.items) |message| {
            if (std.mem.indexOf(u8, message, request.text.?) != null) {
                found += 1;
            }
        }
        return try std.fmt.allocPrint(arena, "{d}", .{found});
    }
    if (std.mem.eql(u8, name, "index-of-containing")) {
        for (recorded.messages.items, 0..) |message, index| {
            if (std.mem.indexOf(u8, message, request.text.?) != null) {
                return try std.fmt.allocPrint(arena, "{d}", .{index});
            }
        }
        return try std.fmt.allocPrint(arena, "{d}", .{std.math.maxInt(usize)});
    }
    if (std.mem.eql(u8, name, "remove-containing")) {
        var index: usize = 0;
        var removed: usize = 0;
        while (index < recorded.messages.items.len) {
            const message = recorded.messages.items[index];
            if (std.mem.indexOf(u8, message, request.text.?) == null) {
                index += 1;
                continue;
            }
            allocator.free(message);
            _ = recorded.messages.orderedRemove(index);
            removed += 1;
        }
        return try std.fmt.allocPrint(arena, "{d}", .{removed});
    }
    if (std.mem.eql(u8, name, "chosen-actions")) {
        return recorded.chosen_actions.items;
    }
    if (std.mem.eql(u8, name, "screenshot-paths")) {
        return recorded.screenshot_paths.items;
    }
    if (std.mem.eql(u8, name, "keep-alive-calls")) {
        return try json.stringify(arena, recorded.keep_alive_calls.items);
    }
    if (std.mem.eql(u8, name, "quit-called")) {
        return if (recorded.quit_called) "1" else "0";
    }
    if (std.mem.eql(u8, name, "last-call")) {
        return recorded.last_calls.get(request.type.?) orelse "";
    }
    std.debug.panic("the fake native app was sent a request it does not know: {s}", .{name});
}

//
// Records a call and gives it its result when it has one: the result the test set for its type, or else what a native app gives.
//
fn handleCall(io: std.Io, allocator: std.mem.Allocator, native: *NativeSide, recorded: *Recorded, text: []const u8, reply: u64) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call = native_message.parse(arena, text) catch {
        std.debug.panic("the core sent the fake native app a call it cannot read: {s}", .{text});
    };
    const call_type = (std.json.parseFromSliceLeaky(struct { type: []const u8 }, arena, text, .{
        .ignore_unknown_fields = true,
    }) catch unreachable).type;
    recorded.recordCall(allocator, call_type, text) catch @panic("out of memory recording a call");
    switch (call) {
        .quit => recorded.quit_called = true,
        .menu_action => |action| {
            recorded.chosen_actions.appendSlice(allocator, action) catch @panic("out of memory");
            recorded.chosen_actions.append(allocator, '\n') catch @panic("out of memory");
        },
        .keep_alive => |keep_running| recorded.keep_alive_calls.append(allocator, keep_running) catch @panic("out of memory"),
        .screenshot => |path| {
            recorded.screenshot_paths.appendSlice(allocator, path) catch @panic("out of memory");
            recorded.screenshot_paths.append(allocator, '\n') catch @panic("out of memory");
        },
        .os_version, .pick_paths, .native_call, .stopped => {},
    }
    if (reply == 0) {
        return;
    }
    const outcome: CallResult = if (recorded.results.get(call_type)) |given| given else (defaultResult(arena, call) catch @panic("out of memory giving a call its result"));
    native.result(io, allocator, reply, outcome.succeeded, outcome.text) catch |err| {
        std.debug.panic("the fake native app could not give a call its result: {s}", .{@errorName(err)});
    };
}

//
// The result a native app gives a call when the test has set none: the operating system "Test OS 1.0"; a dialog that gives its kind,
// its title and its initial name back as the paths chosen; a native call that gives its method and request back, or fails with a reason
// when the method is "fail"; a screenshot that is written, or fails with a reason when the path ends in "refused.png".
//
fn defaultResult(arena: std.mem.Allocator, call: native_message.Call) !CallResult {
    switch (call) {
        .os_version => return .{
            .succeeded = true,
            .text = try arena.dupe(u8, "\"Test OS 1.0\""),
        },
        .pick_paths => |pick| return .{
            .succeeded = true,
            .text = try std.fmt.allocPrint(arena, "[\"kind{d}\",\"{s}\",\"{s}\"]", .{ pick.kind, pick.title orelse "-", pick.initial_name orelse "-" }),
        },
        .native_call => |native_call| {
            if (std.mem.eql(u8, native_call.method, "fail")) {
                return .{
                    .succeeded = false,
                    .text = try arena.dupe(u8, "The phone refused."),
                };
            }
            return .{
                .succeeded = true,
                .text = try std.fmt.allocPrint(arena, "{{\"method\":\"{s}\",\"request\":{s}}}", .{ native_call.method, native_call.request }),
            };
        },
        .screenshot => |path| {
            if (std.mem.endsWith(u8, path, "refused.png")) {
                return .{
                    .succeeded = false,
                    .text = try arena.dupe(u8, "The window cannot be captured."),
                };
            }
            return .{
                .succeeded = true,
                .text = try arena.dupe(u8, ""),
            };
        },
        .quit, .menu_action, .keep_alive, .stopped => std.debug.panic("a call that has no result was given a number for its result", .{}),
    }
}
