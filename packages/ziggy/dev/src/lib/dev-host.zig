//
// Ziggy's dev host: an app's core run as a program of its own for dev mode, with the frontend in an ordinary browser instead of
// the system web view. It plays the part a native app plays, through the same C interface: it creates the core, carries messages
// between the frontend and the core over a WebSocket and does the core's calls to the native app. It also stands in front of the app's own
// dev server: the browser opens the dev host, which serves /__ziggy itself and forwards everything else to the dev server, putting
// its dev script and the inject script at the start of each page on the way through, and passing the dev server's own WebSockets
// through. The dev server needs nothing of Ziggy's.
//
// What only a native app can do (menus, screenshots, the app's own native calls) the dev host does not do, so the core fails each
// with NativeCallMissing. File and folder dialogs are shown by the dev host itself on Linux, through zenity (see pickers.zig), on a
// thread of their own, and are missing on the other platforms. A dropped file is handled too: the browser hands its contents over and
// the dev host saves a copy, whose path is what the frontend gets.
//
// It listens on 127.0.0.1 only. The program's main thread is the dev host's UI thread: it owns the core's handle, the page that
// connected last and the messages waiting for a page, and every other thread talks to it by message (see message-queue.zig): an
// accepting thread, which serves each connection on a thread of its own, the dialog thread, and the core, which posts its messages for
// the native app to the native app's queue and wakes the main thread to take them (see native-message.zig). A message for the page is
// written to the WebSocket of the page that connected last, or kept until a page connects. Each thread allocates with an allocator of
// its own.
//

const std = @import("std");
const builtin = @import("builtin");
const z = @import("c");
const message_queue = @import("message-queue");
const request_paths = @import("request-paths.zig");
const args_lib = @import("args.zig");
const web_socket_lib = @import("web-socket.zig");
const proxy = @import("proxy.zig");
const pickers = @import("pickers.zig");
const native_message = @import("native-message");
const ThreadAllocator = @import("thread-allocator").ThreadAllocator;

const MessageQueue = message_queue.MessageQueue;
const QueueMessage = message_queue.Message;

// Ziggy's dev mode script, which the dev host puts in each page before the inject script. See dev-client.js.
const dev_script = @embedFile("dev-client.js");

// The largest message the frontend may send over the WebSocket. A message is held whole before it goes to the core.
const message_limit = 256 * 1024 * 1024;

// The largest request body or page the dev host holds whole while it forwards it.
const forward_limit = 64 * 1024 * 1024;

//
// What a message to the main thread is, by the number it is sent under.
//
const Hub = struct {
    // A message from the core for the page. The text is the message.
    const deliver: u32 = 1;
    // A message from the page for the core. The text is the message.
    const frontend: u32 = 2;
    // A page has connected. The reply queue is the page's, which the main thread sends the page's messages to from then on.
    const page_connected: u32 = 3;
    // A page has gone. The reply queue is the page's, which the main thread stops sending to, and acknowledges with page_released.
    const page_disconnected: u32 = 4;
    // Messages for the page that a page that went did not write, oldest first. The text is a JSON array of them. They go ahead of every
    // message waiting for a page.
    const undelivered: u32 = 5;
    // A request for the query of the frontend's address. The reply, to the reply queue, is the query, or an empty text with from 1
    // when the app could not make it.
    const ui_query: u32 = 6;
    // A request to record a drop. The text is the JSON array of the paths, and the reply, to the reply queue, is "true" or "false".
    const drop: u32 = 7;
    // The core has posted messages for the native app, which the main thread takes.
    const native: u32 = 8;
    // A dialog's result, from the dialog thread. The text is a PickResult.
    const picked: u32 = 9;
};

//
// A dialog for the dialog thread to show, as the main thread sends it, and its result, as the dialog thread sends it back.
//
const PickRequest = struct {
    // The number the result of the core's call is sent with.
    reply: u64,
    // The kind of dialog, as ziggy.h numbers it.
    kind: i32,
    // The dialog's title, or null.
    title: ?[]const u8 = null,
    // The initial name, or null.
    initialName: ?[]const u8 = null,
};

//
// A dialog's result.
//
const PickResult = struct {
    // The number the result of the core's call is sent with.
    reply: u64,
    // Whether the dialog was shown.
    succeeded: bool,
    // The JSON text of the paths chosen, or the reason the dialog could not be shown.
    text: []const u8,
};

//
// What a message to a page's thread is, by the number it is sent under.
//
const Page = struct {
    // A message from the core to write to the page. The text is the message.
    const deliver: u32 = 1;
    // The main thread will send no more messages to this page.
    const released: u32 = 2;
    // From the page's reading thread: a ping came, and its payload, the text, is to go back as a pong.
    const pong: u32 = 3;
    // From the page's reading thread: the page closed its socket, and the reading thread has ended.
    const closed: u32 = 4;
};

//
// What the dev host's main thread owns. It lives on the stack of run.
//
const DevHost = struct {
    // The command line.
    options: args_lib.DevHostOptions,
    // The core's handle, until it is destroyed.
    core: ?*anyopaque,
    // The main thread's messages. It is never freed: a connection's thread may still post to it while the program ends.
    queue: *MessageQueue,
    // The dialog thread's messages: a PickRequest for each dialog, and "stop".
    picks: *MessageQueue,
    // The queue of the page connected last, or null when none is.
    page: ?*MessageQueue,
    // Messages from the core that arrived while no page was connected, oldest first.
    pending: std.ArrayList([]u8),
    // The port the dev host listens on.
    port: u16,
    // Set once the core has sent the native app a quit call.
    quit_requested: bool,
};

//
// What a connection thread of the dev host keeps while it serves its connection, all of it its own: its copy of what it reads of the
// command line, and the main thread's queue, which it talks to the main thread through. Its Io and allocator are made by the thread
// and given to each function.
//
const Connection = struct {
    // The thread's own copy of the parts of the command line it reads.
    options: ConnectionOptions,
    // The main thread's messages.
    hub: *MessageQueue,
};

//
// The parts of the command line a connection thread reads. It holds its own copy of them, so each thread it is given to has one.
//
const ConnectionOptions = struct {
    // The port the app's own dev server listens on.
    ui_port: u16,
    // The app's data directory, in the first data_dir_len bytes.
    data_dir_buffer: [std.fs.max_path_bytes]u8,
    // The length of the data directory.
    data_dir_len: usize,

    //
    // The options, with a copy of the data directory.
    //
    fn init(ui_port: u16, data_dir: []const u8) !ConnectionOptions {
        if (data_dir.len > std.fs.max_path_bytes) {
            return error.NameTooLong;
        }
        var options: ConnectionOptions = .{
            .ui_port = ui_port,
            .data_dir_buffer = undefined,
            .data_dir_len = data_dir.len,
        };
        @memcpy(options.data_dir_buffer[0..data_dir.len], data_dir);
        return options;
    }

    //
    // The app's data directory.
    //
    fn dataDir(self: *const ConnectionOptions) []const u8 {
        return self.data_dir_buffer[0..self.data_dir_len];
    }
};

//
// What the accepting thread is given when it starts, which it owns from then on.
//
const AcceptStart = struct {
    // The accepting thread's own copy of what each connection thread is given a copy of.
    options: ConnectionOptions,
    // The main thread's messages, which each connection thread talks to the main thread through.
    hub: *MessageQueue,
    // The accepting thread's messages: "stop" from the main thread.
    queue: *MessageQueue,
    // The listening socket, which the accepting thread closes when it ends.
    listener: std.Io.net.Server,
};

//
// What a connection thread is given when it starts, which it owns from then on.
//
const ConnectionStart = struct {
    // The connection thread's own copy of the parts of the command line it reads.
    options: ConnectionOptions,
    // The main thread's messages.
    hub: *MessageQueue,
    // The connection's socket, which the thread closes when it ends.
    stream: std.Io.net.Stream,
};

//
// A single threaded Io of the calling thread's own.
//
fn ownIo(allocator: std.mem.Allocator) std.Io.Threaded {
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    return threaded;
}

//
// Connects to the dev host's own port and closes the connection at once, which wakes the accepting thread from accept so it reads
// the "stop" sent to it before. A connection that cannot be made means the listener is gone and the thread is not in accept.
//
fn wakeAccepting(io: std.Io, port: u16) void {
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    if (address.connect(io, .{ .mode = .stream })) |stream| {
        stream.close(io);
    }
    else |_| {}
}

//
// Runs the dev host and returns the process's exit code.
//
pub fn run(init: std.process.Init, app: AppInfo) !u8 {
    const io = init.io;
    // The main thread's own allocator. Every other thread makes one of its own.
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    const all_args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = args_lib.parseDevHostOptions(all_args[1..]) catch |err| {
        std.debug.print("ziggy dev host: {s}. Usage: --data-dir <dir> --ui-port <port> [--port <port>] [--port-file <file>] [--remote-control <host:port>]\n", .{@errorName(err)});
        return 2;
    };
    try std.Io.Dir.cwd().createDirPath(io, options.data_dir);

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", options.port);
    var listener = address.listen(io, .{
        .reuse_address = true,
    }) catch |err| {
        std.debug.print("ziggy dev host: cannot listen on 127.0.0.1:{d}: {s}\n", .{ options.port, @errorName(err) });
        return 1;
    };
    // The accepting thread owns the listening socket once it starts, and closes it.
    var listener_given = false;
    defer if (!listener_given) listener.deinit(io);

    // Never freed, as the main thread's queue explains: it lives in pages of its own, so the main thread's allocator has nothing left
    // allocated when the thread ends.
    const queue = try std.heap.page_allocator.create(MessageQueue);
    queue.* = MessageQueue.init();
    var picks = MessageQueue.init();
    defer picks.deinit();
    var dev_host = DevHost{
        .options = options,
        .core = null,
        .queue = queue,
        .picks = &picks,
        .page = null,
        .pending = .empty,
        .port = listener.socket.address.getPort(),
        .quit_requested = false,
    };
    defer {
        for (dev_host.pending.items) |text| {
            allocator.free(text);
        }
        dev_host.pending.deinit(allocator);
    }

    const picking = try std.Thread.spawn(.{}, showDialogs, .{ &picks, queue });
    defer {
        picks.post(io, 1, "") catch @panic("out of memory stopping the dialog thread");
        picking.join();
    }

    try createCore(&dev_host, allocator);
    defer destroyCore(&dev_host);

    if (options.port_file) |port_file| {
        var port_text: [8]u8 = undefined;
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = port_file,
            .data = try std.fmt.bufPrint(&port_text, "{d}", .{dev_host.port}),
        });
    }
    std.debug.print("ziggy dev host: the core of {s} is running on 127.0.0.1:{d}\n", .{ app.title, dev_host.port });

    var accept_queue = MessageQueue.init();
    defer accept_queue.deinit();
    const accepting = try std.Thread.spawn(.{}, acceptConnections, .{AcceptStart{
        .options = try ConnectionOptions.init(options.ui_port, options.data_dir),
        .hub = queue,
        .queue = &accept_queue,
        .listener = listener,
    }});
    listener_given = true;
    while (!dev_host.quit_requested) {
        const message = queue.take(io, allocator, .none) orelse {
            break;
        };
        defer allocator.free(message.text);
        handleHubMessage(&dev_host, io, allocator, message);
    }
    try accept_queue.post(io, 0, "stop");
    // The accepting thread blocks in accept, so a connection made here wakes it to read "stop".
    wakeAccepting(io, dev_host.port);
    accepting.join();
    return 0;
}

//
// The accepting thread: accepts each connection and serves it on a thread of its own, until the main thread sends it "stop", then
// closes the listening socket. It blocks in accept, so the main thread wakes it with a connection of its own after sending "stop"
// (wakeAccepting), and it reads its messages after each connection it accepts.
//
fn acceptConnections(given: AcceptStart) void {
    var start = given;
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded = ownIo(allocator);
    defer threaded.deinit();
    const io = threaded.io();
    defer start.listener.deinit(io);
    while (true) {
        const stream = start.listener.accept(io) catch |err| {
            std.debug.print("ziggy dev host: accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        if (start.queue.tryTake(io, allocator)) |message| {
            allocator.free(message.text);
            stream.close(io);
            break;
        }
        const thread = std.Thread.spawn(.{}, serveConnection, .{ConnectionStart{
            .options = start.options,
            .hub = start.hub,
            .stream = stream,
        }}) catch |err| {
            std.debug.print("ziggy dev host: could not serve a connection: {s}\n", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

//
// Handles one message on the main thread.
//
fn handleHubMessage(dev_host: *DevHost, io: std.Io, allocator: std.mem.Allocator, message: QueueMessage) void {
    switch (message.from) {
        Hub.native => takeNativeMessages(dev_host, io, allocator),
        Hub.picked => {
            const core = dev_host.core orelse {
                return;
            };
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const result = std.json.parseFromSliceLeaky(PickResult, arena_state.allocator(), message.text, .{}) catch @panic("the dialog thread sent a result that is not a PickResult");
            z.ziggy_native_result(core, result.reply, result.succeeded, result.text.ptr, result.text.len);
        },
        Hub.frontend => {
            const core = dev_host.core orelse {
                return;
            };
            z.ziggy_send_message(core, message.text.ptr, message.text.len);
        },
        Hub.page_connected => connectPage(dev_host, io, allocator, message.reply_to.?),
        Hub.page_disconnected => {
            const page = message.reply_to.?;
            if (dev_host.page == page) {
                dev_host.page = null;
            }
            page.post(io, Page.released, "") catch @panic("out of memory releasing a page");
        },
        Hub.undelivered => {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const texts = std.json.parseFromSliceLeaky([]const []const u8, arena_state.allocator(), message.text, .{}) catch @panic("the messages a page did not write are not a JSON array of texts");
            for (texts, 0..) |text, index| {
                const copy = allocator.dupe(u8, text) catch @panic("out of memory keeping a message for the page");
                dev_host.pending.insert(allocator, index, copy) catch @panic("out of memory keeping a message for the page");
            }
            if (dev_host.page) |page| {
                sendPending(dev_host, io, allocator, page);
            }
        },
        Hub.ui_query => {
            const reply_to = message.reply_to.?;
            const core = dev_host.core orelse {
                reply_to.post(io, 1, "") catch @panic("out of memory replying to a request for the query");
                return;
            };
            var query_length: usize = 0;
            const query_pointer = z.ziggy_ui_query(core, &query_length) orelse {
                reply_to.post(io, 1, "") catch @panic("out of memory replying to a request for the query");
                return;
            };
            reply_to.post(io, 0, query_pointer[0..query_length]) catch @panic("out of memory replying to a request for the query");
        },
        Hub.drop => {
            const reply_to = message.reply_to.?;
            const core = dev_host.core orelse {
                reply_to.post(io, 0, "false") catch @panic("out of memory replying to a drop");
                return;
            };
            const recorded = z.ziggy_files_dropped(core, message.text.ptr, message.text.len);
            reply_to.post(io, 0, if (recorded) "true" else "false") catch @panic("out of memory replying to a drop");
        },
        else => std.debug.panic("ziggy dev host: the main thread was sent a message it does not know ({d})", .{message.from}),
    }
}

//
// Sends a message from the core to the page connected last, or keeps it until a page connects.
//
fn sendToPage(dev_host: *DevHost, io: std.Io, allocator: std.mem.Allocator, text: []const u8) void {
    if (dev_host.page) |page| {
        page.post(io, Page.deliver, text) catch @panic("out of memory sending a message to the page");
        return;
    }
    const copy = allocator.dupe(u8, text) catch @panic("out of memory keeping a message for the page");
    dev_host.pending.append(allocator, copy) catch @panic("out of memory keeping a message for the page");
}

//
// Makes a page the one messages go to, and sends it the messages that waited for a page.
//
fn connectPage(dev_host: *DevHost, io: std.Io, allocator: std.mem.Allocator, page: *MessageQueue) void {
    dev_host.page = page;
    sendPending(dev_host, io, allocator, page);
}

//
// Sends a page every message that waited for one, oldest first.
//
fn sendPending(dev_host: *DevHost, io: std.Io, allocator: std.mem.Allocator, page: *MessageQueue) void {
    for (dev_host.pending.items) |text| {
        page.post(io, Page.deliver, text) catch @panic("out of memory sending a message to the page");
        allocator.free(text);
    }
    dev_host.pending.clearRetainingCapacity();
}

//
// Creates the core with the dev host's callbacks. Test mode is on when the dev host was started with --remote-control, and the
// core then connects to the remote control server at that address, as in a native app.
//
fn createCore(dev_host: *DevHost, allocator: std.mem.Allocator) !void {
    const app_url_prefix = try std.fmt.allocPrintSentinel(allocator, "http://127.0.0.1:{d}/", .{dev_host.port}, 0);
    defer allocator.free(app_url_prefix);
    const data_dir = try allocator.dupeZ(u8, dev_host.options.data_dir);
    defer allocator.free(data_dir);
    const remote_control: ?[:0]u8 = if (dev_host.options.remote_control) |address| try allocator.dupeZ(u8, address) else null;
    defer if (remote_control) |address| allocator.free(address);

    var config = std.mem.zeroes(z.ziggy_config);
    config.wake_data = dev_host.queue;
    config.wake = wake;
    config.has_quit = true;
    config.has_os_version = true;
    config.has_pick_paths = builtin.os.tag == .linux;
    config.worker_threads = @intCast(std.Thread.getCpuCount() catch 4);
    config.max_concurrent_child_tasks = 10;
    config.app_url_prefix = app_url_prefix.ptr;
    config.data_dir = data_dir.ptr;
    if (remote_control) |address| {
        config.test_mode = true;
        config.remote_control = address.ptr;
    }
    dev_host.core = z.ziggy_create(&config) orelse {
        return error.CoreCreateFailed;
    };
}

//
// Destroys the core once, on the main thread. After it nothing more is delivered and no message reaches it.
//
fn destroyCore(dev_host: *DevHost) void {
    const core = dev_host.core orelse {
        return;
    };
    dev_host.core = null;
    z.ziggy_destroy(core);
}

//
// The core's wake. It runs on any thread of the core or the app, and posts to the main thread's queue, given as the wake data, that
// the core has messages for the native app, which the main thread then takes.
//
fn wake(wake_data: ?*anyopaque) callconv(.c) void {
    const queue: *MessageQueue = @ptrCast(@alignCast(wake_data.?));
    // A post needs an Io of the calling thread's own, which allocates nothing for it, so its allocator is a buffer on the stack.
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var threaded = ownIo(fixed.allocator());
    defer threaded.deinit();
    queue.post(threaded.io(), Hub.native, "") catch @panic("out of memory waking the dev host");
}

//
// Takes every message the core has posted for the native app, on the main thread: a message for the page goes to the page, a quit
// ends the dev host, the operating system's version is sent at once, and a dialog goes to the dialog thread, whose result
// is sent later.
//
fn takeNativeMessages(dev_host: *DevHost, io: std.Io, allocator: std.mem.Allocator) void {
    const core = dev_host.core orelse {
        return;
    };
    while (true) {
        var length: usize = 0;
        var kind: i32 = 0;
        var reply: u64 = 0;
        const text_pointer = z.ziggy_take_native_message(core, &length, &kind, &reply) orelse {
            return;
        };
        const text = text_pointer[0..length];
        if (kind == z.ZIGGY_NATIVE_DELIVER) {
            sendToPage(dev_host, io, allocator, text);
            continue;
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const call = native_message.parse(arena, text) catch {
            std.debug.panic("ziggy dev host: the core sent a call the dev host cannot read: {s}", .{text});
        };
        switch (call) {
            .quit => dev_host.quit_requested = true,
            .os_version => {
                var buffer: [256]u8 = undefined;
                const version = osVersion(&buffer) catch |err| {
                    const reason = @errorName(err);
                    z.ziggy_native_result(core, reply, false, reason.ptr, reason.len);
                    continue;
                };
                z.ziggy_native_result(core, reply, true, version.ptr, version.len);
            },
            .pick_paths => |pick| {
                const request = std.json.Stringify.valueAlloc(arena, PickRequest{
                    .reply = reply,
                    .kind = pick.kind,
                    .title = pick.title,
                    .initialName = pick.initial_name,
                }, .{}) catch @panic("out of memory requesting a dialog");
                dev_host.picks.post(io, 0, request) catch @panic("out of memory requesting a dialog");
            },
            else => std.debug.panic("ziggy dev host: the core sent a call the dev host does not do: {s}", .{text}),
        }
    }
}

//
// The dialog thread: shows each dialog the main thread sends it, one at a time, and sends the main thread each result, until it is
// sent "stop" (from 1). A dialog is a program of its own, which this thread waits for, so the main thread never does.
//
fn showDialogs(picks: *MessageQueue, hub: *MessageQueue) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded = ownIo(allocator);
    defer threaded.deinit();
    const io = threaded.io();
    while (true) {
        const message = picks.take(io, allocator, .none) orelse {
            return;
        };
        defer allocator.free(message.text);
        if (message.from == 1) {
            return;
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const request = std.json.parseFromSliceLeaky(PickRequest, arena, message.text, .{}) catch @panic("the main thread requested a dialog with a message that is not a PickRequest");
        const result: PickResult = if (pickers.kindFromInt(request.kind)) |dialog_kind| shown: {
            const json = pickers.pick(io, arena, dialog_kind, request.title, request.initialName) catch |err| {
                std.debug.print("ziggy dev host: the dialog failed: {s}\n", .{@errorName(err)});
                break :shown .{
                    .reply = request.reply,
                    .succeeded = false,
                    .text = @errorName(err),
                };
            };
            break :shown .{
                .reply = request.reply,
                .succeeded = true,
                .text = json,
            };
        } else .{
            .reply = request.reply,
            .succeeded = false,
            .text = "NoSuchDialogKind",
        };
        const text = std.json.Stringify.valueAlloc(arena, result, .{}) catch @panic("out of memory sending a dialog's result");
        hub.post(io, Hub.picked, text) catch @panic("out of memory sending a dialog's result");
    }
}

//
// What the dev host is told about the app by the app's build.
//
pub const AppInfo = struct {
    // The app's name as people see it, for the messages the dev host writes.
    title: []const u8,
};

//
// The operating system's version as the JSON text of a string, written into the buffer.
//
fn osVersion(buffer: []u8) ![]u8 {
    // Windows has no uname, so its version is read from the kernel, as the Windows native app does.
    if (builtin.os.tag == .windows) {
        var windows_info = std.mem.zeroes(std.os.windows.RTL_OSVERSIONINFOW);
        windows_info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
        if (std.os.windows.ntdll.RtlGetVersion(&windows_info) != .SUCCESS) {
            return error.VersionUnavailable;
        }
        return try std.fmt.bufPrint(buffer, "\"Windows {d}.{d}.{d} {s}\"", .{
            windows_info.dwMajorVersion,
            windows_info.dwMinorVersion,
            windows_info.dwBuildNumber,
            @tagName(builtin.cpu.arch),
        });
    }
    var info: std.c.utsname = undefined;
    if (std.c.uname(&info) != 0) {
        return error.VersionUnavailable;
    }
    var version_buffer: [256]u8 = undefined;
    const version = try std.fmt.bufPrint(&version_buffer, "{s} {s} {s}", .{
        std.mem.sliceTo(&info.sysname, 0),
        std.mem.sliceTo(&info.release, 0),
        std.mem.sliceTo(&info.machine, 0),
    });
    // The version is written as a JSON string, so the JSON writer does the quoting and escaping.
    return try std.fmt.bufPrint(buffer, "{f}", .{std.json.fmt(version, .{})});
}

//
// Serves the requests of one connection until it closes, on a thread of its own. A request for the WebSocket turns the connection into
// the page's socket for the rest of its life.
//
fn serveConnection(start: ConnectionStart) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded = ownIo(allocator);
    defer threaded.deinit();
    const io = threaded.io();
    const connection: Connection = .{
        .options = start.options,
        .hub = start.hub,
    };
    const stream = start.stream;
    defer stream.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    while (true) {
        var request = http_server.receiveHead() catch {
            return;
        };
        const own = std.mem.startsWith(u8, request.head.target, "/__ziggy/");
        switch (request.upgradeRequested()) {
            .websocket => |key| {
                if (!own) {
                    // The dev server's own WebSocket, such as its live reload, is passed through untouched.
                    tunnelToDevServer(connection, io, stream, &reader.interface, &request) catch |err| {
                        std.debug.print("ziggy dev host: the dev server's WebSocket ended: {s}\n", .{@errorName(err)});
                    };
                    return;
                }
                if (!std.mem.eql(u8, request.head.target, "/__ziggy/socket")) {
                    request.respond("Not found\n", .{
                        .status = .not_found,
                        .keep_alive = false,
                    }) catch {};
                    return;
                }
                serveSocket(connection, io, allocator, stream, &request, key orelse "") catch |err| {
                    std.debug.print("ziggy dev host: the page's connection ended: {s}\n", .{@errorName(err)});
                };
                return;
            },
            else => {},
        }
        if (!own) {
            // The dev server's response ends with its connection, so this connection ends after it too.
            forwardToDevServer(connection, io, allocator, &request, &writer.interface) catch |err| {
                std.debug.print("ziggy dev host: forwarding {s} to the app's dev server failed: {s}\n", .{ request.head.target, @errorName(err) });
            };
            return;
        }
        serveRequest(connection, io, allocator, &request) catch |err| {
            std.debug.print("ziggy dev host: a request for {s} failed: {s}\n", .{ request.head.target, @errorName(err) });
            return;
        };
    }
}

//
// Serves one ordinary request.
//
fn serveRequest(connection: Connection, io: std.Io, allocator: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    if (request.head.method == .POST) {
        if (std.mem.startsWith(u8, target, "/__ziggy/dropped-file?")) {
            return saveDroppedFile(connection, io, allocator, request);
        }
        if (std.mem.eql(u8, target, "/__ziggy/drop")) {
            return recordDrop(connection, io, allocator, request);
        }
    }
    else {
        if (std.mem.eql(u8, target, "/__ziggy/alive")) {
            return request.respond("ok", .{
                .extra_headers = &.{
                    .{
                        .name = "cache-control",
                        .value = "no-store",
                    },
                },
            });
        }
        if (std.mem.eql(u8, target, "/__ziggy/dev.js")) {
            return respondWithScript(request, dev_script);
        }
        if (std.mem.eql(u8, target, "/__ziggy/inject.js")) {
            var length: usize = 0;
            const script = z.ziggy_inject_script(&length);
            return respondWithScript(request, script[0..length]);
        }
        if (std.mem.eql(u8, target, "/__ziggy/start")) {
            return redirectToIndex(connection, io, allocator, request);
        }
    }
    return request.respond("Not found\n", .{
        .status = .not_found,
    });
}

//
// Responds with a script, which the browser is told never to keep, so a reload after a rebuild gets the new one.
//
fn respondWithScript(request: *std.http.Server.Request, script: []const u8) !void {
    return request.respond(script, .{
        .extra_headers = &.{
            .{
                .name = "content-type",
                .value = "text/javascript; charset=utf-8",
            },
            .{
                .name = "cache-control",
                .value = "no-store",
            },
        },
    });
}

//
// Sends the main thread a request and waits for its reply, which it always sends. The reply's text is the caller's to free with the
// connection's allocator.
//
fn requestFromMain(connection: Connection, io: std.Io, allocator: std.mem.Allocator, replies: *MessageQueue, kind: u32, text: []const u8) !QueueMessage {
    try connection.hub.postReplyTo(io, kind, text, replies);
    return replies.take(io, allocator, .none) orelse {
        @panic("ziggy dev host: a reply queue closed while a thread waited for the main thread");
    };
}

//
// Sends the browser to index.html with the query the app makes, as a native app loads it. A browser opened at /__ziggy/start gets
// the frontend as a native app shows it, test mode switch included.
//
fn redirectToIndex(connection: Connection, io: std.Io, allocator: std.mem.Allocator, request: *std.http.Server.Request) !void {
    var replies = MessageQueue.init();
    defer replies.deinit();
    const reply = try requestFromMain(connection, io, allocator, &replies, Hub.ui_query, "");
    defer allocator.free(reply.text);
    if (reply.from != 0) {
        return error.UiQueryFailed;
    }
    const query = reply.text;
    const location = try std.fmt.allocPrint(allocator, "/index.html{s}{s}", .{ if (query.len > 0) "?" else "", query });
    defer allocator.free(location);
    return request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{
                .name = "location",
                .value = location,
            },
        },
    });
}

//
// Saves the body of the request, the contents of one dropped file, as a copy under the data directory, and responds with the copy's
// path. The name comes from the query's name parameter. Each drop's copies go in a directory of their own, named after the time and a
// random number.
//
fn saveDroppedFile(connection: Connection, io: std.Io, allocator: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const encoded_name = request_paths.queryParameter(request.head.target, "name") orelse "";
    var name_buffer: [1024]u8 = undefined;
    const decoded = request_paths.percentDecode(&name_buffer, encoded_name) catch {
        return request.respond("The name of the dropped file is not encoded properly.", .{
            .status = .bad_request,
        });
    };
    const name = request_paths.droppedFileName(decoded) catch {
        return request.respond("The dropped file has no name a file can be saved under.", .{
            .status = .bad_request,
        });
    };
    var random_bytes: [4]u8 = undefined;
    io.random(&random_bytes);
    var drop_name_buffer: [64]u8 = undefined;
    const drop_name = try std.fmt.bufPrint(&drop_name_buffer, "{d}-{d}", .{ std.Io.Clock.real.now(io).toMilliseconds(), std.mem.readInt(u32, &random_bytes, .little) });
    const directory = try std.fs.path.join(allocator, &.{ connection.options.dataDir(), "dropped", drop_name });
    defer allocator.free(directory);
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const copy_path = try std.fs.path.join(allocator, &.{ directory, name });
    defer allocator.free(copy_path);
    const absolute_directory = try std.Io.Dir.cwd().realPathFileAlloc(io, directory, allocator);
    defer allocator.free(absolute_directory);
    const absolute_copy_path = try std.fs.path.join(allocator, &.{ absolute_directory, name });
    defer allocator.free(absolute_copy_path);

    var body_buffer: [64 * 1024]u8 = undefined;
    const body = try request.readerExpectContinue(&body_buffer);
    var file = try std.Io.Dir.cwd().createFile(io, copy_path, .{});
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    _ = try body.streamRemaining(&file_writer.interface);
    try file_writer.interface.flush();
    return request.respond(absolute_copy_path, .{
        .extra_headers = &.{
            .{
                .name = "content-type",
                .value = "text/plain; charset=utf-8",
            },
        },
    });
}

//
// Records a drop with the core, through the main thread: the body is the JSON array of the copies' paths, as a native app records the
// paths it read.
//
fn recordDrop(connection: Connection, io: std.Io, allocator: std.mem.Allocator, request: *std.http.Server.Request) !void {
    var body_buffer: [64 * 1024]u8 = undefined;
    const body = try request.readerExpectContinue(&body_buffer);
    const paths_json = try body.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(paths_json);
    var replies = MessageQueue.init();
    defer replies.deinit();
    const reply = try requestFromMain(connection, io, allocator, &replies, Hub.drop, paths_json);
    defer allocator.free(reply.text);
    if (!std.mem.eql(u8, reply.text, "true")) {
        return request.respond("The core would not record the drop. The dev host's output says why.", .{
            .status = .bad_request,
        });
    }
    return request.respond("", .{
        .status = .no_content,
    });
}

// Forwards one request to the app's dev server and writes its response to the browser. A page gets Ziggy's scripts on the way through,
// and anything else is passed on as it came. Responds to the browser itself when the dev server cannot be reached.
//
fn forwardToDevServer(connection: Connection, io: std.Io, allocator: std.mem.Allocator, request: *std.http.Server.Request, client: *std.Io.Writer) !void {
    // Copied first: reading the body reuses the buffer the head is in.
    const browser_head = try allocator.dupe(u8, request.head_buffer);
    defer allocator.free(browser_head);
    const is_get = request.head.method == .GET;
    var body: ?[]u8 = null;
    defer if (body) |bytes| allocator.free(bytes);
    if (request.head.method.requestHasBody() and (request.head.content_length != null or request.head.transfer_encoding != .none)) {
        var body_buffer: [64 * 1024]u8 = undefined;
        const body_reader = try request.readerExpectContinue(&body_buffer);
        body = try body_reader.allocRemaining(allocator, .limited(forward_limit));
    }
    const upstream_head = try proxy.upstreamRequestHead(allocator, browser_head, if (body) |bytes| bytes.len else null);
    defer allocator.free(upstream_head);

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", connection.options.ui_port);
    const upstream = address.connect(io, .{
        .mode = .stream,
    }) catch |err| {
        var message_buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "The app's dev server is not answering on 127.0.0.1:{d}: {s}", .{ connection.options.ui_port, @errorName(err) }) catch "The app's dev server is not answering.";
        return request.respond(message, .{
            .status = .bad_gateway,
            .keep_alive = false,
        });
    };
    defer upstream.close(io);
    var upstream_write_buffer: [64 * 1024]u8 = undefined;
    var upstream_writer = upstream.writer(io, &upstream_write_buffer);
    try upstream_writer.interface.writeAll(upstream_head);
    if (body) |bytes| {
        try upstream_writer.interface.writeAll(bytes);
    }
    try upstream_writer.interface.flush();

    var upstream_read_buffer: [64 * 1024]u8 = undefined;
    var upstream_reader = upstream.reader(io, &upstream_read_buffer);
    var response_head: std.ArrayList(u8) = .empty;
    defer response_head.deinit(allocator);
    while (true) {
        const line = try upstream_reader.interface.takeDelimiterInclusive('\n');
        try response_head.appendSlice(allocator, line);
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r\n"), "")) {
            break;
        }
    }
    const parsed = try proxy.parseResponseHead(response_head.items);
    if (!parsed.html or !is_get) {
        try client.writeAll(response_head.items);
        _ = try upstream_reader.interface.streamRemaining(client);
        return client.flush();
    }
    const page = if (parsed.chunked)
        try proxy.readChunkedBody(allocator, &upstream_reader.interface, forward_limit)
    else if (parsed.content_length) |length|
        try upstream_reader.interface.readAlloc(allocator, length)
    else
        try upstream_reader.interface.allocRemaining(allocator, .limited(forward_limit));
    defer allocator.free(page);
    const with_scripts = try proxy.withDevScripts(allocator, page);
    defer allocator.free(with_scripts);
    const page_head = try proxy.pageResponseHead(allocator, response_head.items, with_scripts.len);
    defer allocator.free(page_head);
    try client.writeAll(page_head);
    try client.writeAll(with_scripts);
    return client.flush();
}


//
// Passes a WebSocket the dev server serves, such as its live reload, through to it: the browser's request goes to the dev server as
// it came, and from then on bytes are copied both ways until either side closes: from the browser on this thread, and from the dev
// server on a thread of its own (copyToBrowser), each with buffers of its own.
//
fn tunnelToDevServer(connection: Connection, io: std.Io, browser: std.Io.net.Stream, browser_reader: *std.Io.Reader, request: *std.http.Server.Request) !void {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", connection.options.ui_port);
    const upstream = try address.connect(io, .{
        .mode = .stream,
    });
    defer upstream.close(io);
    var upstream_write_buffer: [64 * 1024]u8 = undefined;
    var upstream_writer = upstream.writer(io, &upstream_write_buffer);
    try upstream_writer.interface.writeAll(request.head_buffer);
    // Bytes the browser sent after its request that were read along with it.
    const early = browser_reader.buffered();
    try upstream_writer.interface.writeAll(early);
    browser_reader.toss(early.len);
    try upstream_writer.interface.flush();

    const back = try std.Thread.spawn(.{}, copyToBrowser, .{ upstream, browser });
    copyAsItComes(browser_reader, &upstream_writer.interface) catch {};
    // The browser has gone, so the dev server's side is ended too, which ends the copy the other way.
    upstream.shutdown(io, .both) catch {};
    back.join();
}

//
// Copies what the dev server sends on a tunnelled WebSocket to the browser until either side closes, on a thread of its own with its
// own Io and buffers. It is given the two sockets and nothing else.
//
fn copyToBrowser(upstream: std.Io.net.Stream, browser: std.Io.net.Stream) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded = ownIo(thread_allocator.allocator());
    defer threaded.deinit();
    const io = threaded.io();
    var read_buffer: [64 * 1024]u8 = undefined;
    var upstream_reader = upstream.reader(io, &read_buffer);
    var browser_write_buffer: [64 * 1024]u8 = undefined;
    var browser_writer = browser.writer(io, &browser_write_buffer);
    copyAsItComes(&upstream_reader.interface, &browser_writer.interface) catch {};
    // The dev server has gone, so the browser's side is ended too, which ends the copy the other way.
    browser.shutdown(io, .both) catch {};
}

//
// Copies everything the reader gets to the writer as it comes, sending each piece at once, until the reader's side closes. A
// WebSocket's frames have to reach the other side when they are sent, not when a buffer fills.
//
fn copyAsItComes(reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    while (true) {
        const piece = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        try writer.writeAll(piece);
        try writer.flush();
        reader.toss(piece.len);
    }
}

//
// Serves the page's WebSocket: every message the page sends goes to the core through the main thread, and every message the main
// thread sends this page is written to it, until the page closes it. This thread writes to the page; a thread of its own
// (readPage) reads from it, posts the page's messages to the main thread and posts this thread the pings to reply to and the
// page's close.
//
fn serveSocket(connection: Connection, io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, request: *std.http.Server.Request, key: []const u8) !void {
    var web_socket = try request.respondWebSocket(.{
        .key = key,
    });
    try web_socket.flush();
    var queue = MessageQueue.init();
    defer queue.deinit();
    try connection.hub.postReplyTo(io, Hub.page_connected, "", &queue);
    // The message the page's socket failed on, which goes back to the main thread when the page is let go, ahead of the ones after it.
    var unwritten: ?[]u8 = null;
    defer releasePage(connection, io, allocator, &queue, unwritten);
    const reading = try std.Thread.spawn(.{}, readPage, .{ReadPageStart{
        .hub = connection.hub,
        .queue = &queue,
        .stream = stream,
    }});
    defer reading.join();
    while (true) {
        const message = queue.take(io, allocator, .none) orelse {
            @panic("ziggy dev host: a page's queue closed while it was served");
        };
        defer allocator.free(message.text);
        if (message.from == Page.closed) {
            return;
        }
        const kind: std.http.Server.WebSocket.Opcode = if (message.from == Page.pong) .pong else .text;
        web_socket.writeMessage(message.text, kind) catch |err| {
            std.debug.print("ziggy dev host: the page's connection failed while a message was written to it: {s}. The message waits for the next page.\n", .{@errorName(err)});
            if (kind == .text) {
                unwritten = try allocator.dupe(u8, message.text);
            }
            // Ends the reading thread's read of the broken connection, then waits for its close.
            stream.shutdown(io, .both) catch {};
            waitForPageClosed(io, allocator, &queue);
            return;
        };
    }
}

//
// Waits for the reading thread's report that it has ended, after the writing side failed. Messages from the main thread that come
// meanwhile are left for releasePage, which takes them in order.
//
fn waitForPageClosed(io: std.Io, allocator: std.mem.Allocator, queue: *MessageQueue) void {
    var kept: std.ArrayList(QueueMessage) = .empty;
    defer kept.deinit(allocator);
    while (true) {
        const message = queue.take(io, allocator, .none) orelse {
            @panic("ziggy dev host: a page's queue closed while it was served");
        };
        if (message.from == Page.closed) {
            allocator.free(message.text);
            break;
        }
        if (message.from == Page.pong) {
            allocator.free(message.text);
            continue;
        }
        kept.append(allocator, message) catch @panic("out of memory letting a page go");
    }
    for (kept.items) |message| {
        queue.post(io, message.from, message.text) catch @panic("out of memory letting a page go");
        allocator.free(message.text);
    }
}

//
// What the page's reading thread is given when it starts.
//
const ReadPageStart = struct {
    // The dev host's main thread's queue, where the page's messages go.
    hub: *MessageQueue,
    // The page's writing thread's queue, where pings and the page's close go.
    queue: *MessageQueue,
    // The page's socket, which this thread only reads from.
    stream: std.Io.net.Stream,
};

//
// The page's reading thread: reads the page's messages until it closes its socket, with its own Io, allocator and buffer. Each
// message goes to the main thread, each ping to the writing thread to reply to, and when the page has gone it tells the writing
// thread so and ends.
//
fn readPage(start: ReadPageStart) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded = ownIo(allocator);
    defer threaded.deinit();
    const io = threaded.io();
    defer start.queue.post(io, Page.closed, "") catch @panic("out of memory ending a page");
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = start.stream.reader(io, &read_buffer);
    while (true) {
        const message = web_socket_lib.readMessage(&reader.interface, allocator, message_limit, .{
            .context = start.queue,
            .answer = answerPing,
        }) catch {
            return;
        };
        switch (message) {
            .data => |text| {
                defer allocator.free(text);
                start.hub.post(io, Hub.frontend, text) catch @panic("out of memory passing on a message from the page");
            },
            .close => return,
        }
    }
}

//
// Tells the main thread the page has gone and waits for it to report it will send the page nothing more. The messages it sent meanwhile,
// which the page did not write, go back to it, to wait for the next page ahead of everything else.
//
fn releasePage(connection: Connection, io: std.Io, allocator: std.mem.Allocator, queue: *MessageQueue, unwritten: ?[]u8) void {
    connection.hub.postReplyTo(io, Hub.page_disconnected, "", queue) catch @panic("out of memory letting a page go");
    var undelivered: std.ArrayList([]const u8) = .empty;
    if (unwritten) |text| {
        undelivered.append(allocator, text) catch @panic("out of memory letting a page go");
    }
    defer {
        for (undelivered.items) |text| {
            allocator.free(text);
        }
        undelivered.deinit(allocator);
    }
    while (true) {
        const message = queue.take(io, allocator, .none) orelse {
            @panic("ziggy dev host: a page's queue closed while it was let go");
        };
        defer allocator.free(message.text);
        if (message.from == Page.released) {
            break;
        }
        undelivered.append(allocator, allocator.dupe(u8, message.text) catch @panic("out of memory letting a page go")) catch @panic("out of memory letting a page go");
    }
    if (undelivered.items.len > 0) {
        returnUndelivered(connection, io, allocator, undelivered.items) catch @panic("out of memory letting a page go");
    }
}

//
// Sends the main thread messages for the page that were not written, oldest first, to wait for the next page.
//
fn returnUndelivered(connection: Connection, io: std.Io, allocator: std.mem.Allocator, texts: []const []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, texts, .{});
    defer allocator.free(json);
    try connection.hub.post(io, Hub.undelivered, json);
}

//
// Has the writing thread reply to a ping with a pong carrying its payload, since only the writing thread writes to the page. The
// context is the writing thread's queue.
//
fn answerPing(context: *anyopaque, payload: []const u8) anyerror!void {
    const queue: *MessageQueue = @ptrCast(@alignCast(context));
    // A post needs an Io of the calling thread's own, which allocates nothing for it, so its allocator is a buffer on the stack.
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var threaded = ownIo(fixed.allocator());
    defer threaded.deinit();
    try queue.post(threaded.io(), Page.pong, payload);
}
