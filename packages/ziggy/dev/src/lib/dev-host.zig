//
// Ziggy's dev host: an app's core run as a program of its own for dev mode, with the UI in an ordinary browser instead of the
// system web view. It plays the part a native app plays, through the same C interface: it creates the core, carries messages
// between the UI and the core over a WebSocket and answers the core's native host callbacks. It also stands in front of the app's own
// dev server: the browser opens the dev host, which answers /__ziggy itself and forwards everything else to the dev server, putting
// its dev script and the inject script at the start of each page on the way through, and passing the dev server's own WebSockets
// through. The dev server needs nothing of Ziggy's.
//
// What only a native app can do (menus, screenshots, the app's own host requests) has no callback here, so the core answers each
// with HostCallbackMissing. File and folder dialogs are shown by the dev host itself on Linux, through zenity (see pickers.zig), and
// are missing on the other platforms. A dropped file is handled too: the browser hands its contents over and the dev host saves a
// copy, whose path is what the UI gets.
//
// It listens on 127.0.0.1 only. Each connection is served on a thread of its own. Messages from the core arrive on any thread and
// are written to the WebSocket of the page that connected last, or kept until a page connects.
//

const std = @import("std");
const builtin = @import("builtin");
const z = @import("c");
const request_paths = @import("request-paths.zig");
const args_lib = @import("args.zig");
const web_socket_lib = @import("web-socket.zig");
const proxy = @import("proxy.zig");
const pickers = @import("pickers.zig");

// Ziggy's dev mode script, which the dev host puts in each page before the inject script. See dev-client.js.
const dev_script = @embedFile("dev-client.js");

// The largest message the UI may send over the WebSocket. A message is held whole before it goes to the core.
const message_limit = 256 * 1024 * 1024;

// The largest request body or page the dev host holds whole while it forwards it.
const forward_limit = 64 * 1024 * 1024;

//
// What the dev host is told about the app by the app's build.
//
pub const AppInfo = struct {
    // The app's name as people see it, for the messages the dev host writes.
    title: []const u8,
};

//
// The page connected over the WebSocket. Messages from the core are written to it.
//
const Socket = struct {
    // The WebSocket, whose writer is used only while the host's socket mutex is held.
    web_socket: std.http.Server.WebSocket,
};

//
// Everything one running dev host owns. It lives on the stack of run and every callback is given its address.
//
const DevHost = struct {
    // The Io every thread uses.
    io: std.Io,
    // A thread safe allocator.
    allocator: std.mem.Allocator,
    // The command line.
    options: args_lib.DevHostOptions,
    // The core's handle, until it is destroyed.
    core: ?*anyopaque,
    // Held while a message is handed to the core and while the core is destroyed, so neither happens during the other.
    core_mutex: std.Io.Mutex,
    // Held while the socket or the waiting messages are used.
    socket_mutex: std.Io.Mutex,
    // The page connected last, or null when none is.
    socket: ?*Socket,
    // Messages from the core that arrived while no page was connected, oldest first.
    waiting: std.ArrayList([]u8),
    // Set when the core has been destroyed, so nothing more is delivered.
    destroyed: std.atomic.Value(bool),
    // Set when the app asked to quit, so the accepting loop ends.
    stopping: std.atomic.Value(bool),
    // The port the dev host listens on.
    port: u16,
    // Counts the drops, so each drop's copies go in a directory of their own.
    drop_count: std.atomic.Value(u32),
};

//
// Runs the dev host and returns the process's exit code.
//
pub fn run(init: std.process.Init, app: AppInfo) !u8 {
    const io = init.io;
    const allocator = std.heap.smp_allocator;
    const all_args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = args_lib.parseDevHostOptions(all_args[1..]) catch |err| {
        std.debug.print("ziggy dev host: {s}. Usage: --data-dir <dir> [--port <port>] [--port-file <file>]\n", .{@errorName(err)});
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
    defer listener.deinit(io);

    var host = DevHost{
        .io = io,
        .allocator = allocator,
        .options = options,
        .core = null,
        .core_mutex = .init,
        .socket_mutex = .init,
        .socket = null,
        .waiting = .empty,
        .destroyed = .init(false),
        .stopping = .init(false),
        .port = listener.socket.address.getPort(),
        .drop_count = .init(0),
    };
    defer {
        for (host.waiting.items) |text| {
            allocator.free(text);
        }
        host.waiting.deinit(allocator);
    }

    try createCore(&host, init.environ_map);
    defer destroyCore(&host);

    if (options.port_file) |port_file| {
        var port_text: [8]u8 = undefined;
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = port_file,
            .data = try std.fmt.bufPrint(&port_text, "{d}", .{host.port}),
        });
    }
    std.debug.print("ziggy dev host: the core of {s} is running on 127.0.0.1:{d}\n", .{ app.title, host.port });

    while (!host.stopping.load(.acquire)) {
        const stream = listener.accept(io) catch |err| {
            std.debug.print("ziggy dev host: accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        if (host.stopping.load(.acquire)) {
            stream.close(io);
            break;
        }
        const thread = std.Thread.spawn(.{}, serveConnection, .{ &host, stream }) catch |err| {
            std.debug.print("ziggy dev host: could not serve a connection: {s}\n", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
    return 0;
}

//
// Creates the core with the dev host's callbacks. Test mode is on when the core was built with the test hooks and
// ZIGGY_TEST_MODE is set, as in a native app, and the control connection's port goes to ZIGGY_TEST_PORT_FILE.
//
fn createCore(host: *DevHost, environ_map: *std.process.Environ.Map) !void {
    const app_url_prefix = try std.fmt.allocPrintSentinel(host.allocator, "http://127.0.0.1:{d}/", .{host.port}, 0);
    defer host.allocator.free(app_url_prefix);
    const data_dir = try host.allocator.dupeZ(u8, host.options.data_dir);
    defer host.allocator.free(data_dir);
    var test_port_file: ?[:0]u8 = null;
    defer if (test_port_file) |path| host.allocator.free(path);

    var config = std.mem.zeroes(z.ziggy_config);
    config.user_data = host;
    config.deliver = deliver;
    config.quit = quit;
    if (builtin.os.tag != .windows) {
        config.os_version = osVersion;
    }
    if (builtin.os.tag == .linux) {
        config.pick_paths = pickPaths;
    }
    config.worker_threads = @intCast(std.Thread.getCpuCount() catch 4);
    config.max_concurrent_child_tasks = 10;
    config.app_url_prefix = app_url_prefix.ptr;
    config.data_dir = data_dir.ptr;
    if (z.ziggy_test_hooks_enabled() and environ_map.get("ZIGGY_TEST_MODE") != null) {
        config.test_mode = true;
        if (environ_map.get("ZIGGY_TEST_PORT_FILE")) |path| {
            test_port_file = try host.allocator.dupeZ(u8, path);
            config.test_port_file = test_port_file.?.ptr;
        }
    }
    host.core = z.ziggy_create(&config) orelse {
        return error.CoreCreateFailed;
    };
}

//
// Destroys the core once. After it nothing more is delivered and no message reaches it.
//
fn destroyCore(host: *DevHost) void {
    host.core_mutex.lockUncancelable(host.io);
    defer host.core_mutex.unlock(host.io);
    const core = host.core orelse {
        return;
    };
    host.destroyed.store(true, .release);
    host.core = null;
    z.ziggy_destroy(core);
}

//
// Hands a message from the UI to the core.
//
fn postToCore(host: *DevHost, text: []const u8) void {
    host.core_mutex.lockUncancelable(host.io);
    defer host.core_mutex.unlock(host.io);
    const core = host.core orelse {
        return;
    };
    z.ziggy_post_message(core, text.ptr, text.len);
}

//
// The core's deliver callback. It runs on any thread: the message goes to the connected page, or waits for one.
//
fn deliver(user_data: ?*anyopaque, message: [*c]const u8, message_len: usize) callconv(.c) void {
    const host: *DevHost = @ptrCast(@alignCast(user_data.?));
    if (host.destroyed.load(.acquire)) {
        return;
    }
    const text = message[0..message_len];
    host.socket_mutex.lockUncancelable(host.io);
    defer host.socket_mutex.unlock(host.io);
    if (host.socket) |socket| {
        if (socket.web_socket.writeMessage(text, .text)) |_| {
            return;
        }
        else |err| {
            std.debug.print("ziggy dev host: the page's connection failed while a message was written to it: {s}. The message waits for the next page.\n", .{@errorName(err)});
            host.socket = null;
        }
    }
    const copy = host.allocator.dupe(u8, text) catch @panic("out of memory keeping a message for the page");
    host.waiting.append(host.allocator, copy) catch @panic("out of memory keeping a message for the page");
}

//
// Makes the socket the one messages go to, and writes it the messages that waited for a page.
//
fn connectSocket(host: *DevHost, socket: *Socket) !void {
    host.socket_mutex.lockUncancelable(host.io);
    defer host.socket_mutex.unlock(host.io);
    host.socket = socket;
    for (host.waiting.items, 0..) |text, index| {
        socket.web_socket.writeMessage(text, .text) catch |err| {
            // The ones not yet written keep waiting.
            for (host.waiting.items[0..index]) |written| {
                host.allocator.free(written);
            }
            host.waiting.replaceRangeAssumeCapacity(0, index, &.{});
            host.socket = null;
            return err;
        };
    }
    for (host.waiting.items) |text| {
        host.allocator.free(text);
    }
    host.waiting.clearRetainingCapacity();
}

//
// Stops messages going to the socket, when it is still the one they go to.
//
fn disconnectSocket(host: *DevHost, socket: *Socket) void {
    host.socket_mutex.lockUncancelable(host.io);
    defer host.socket_mutex.unlock(host.io);
    if (host.socket == socket) {
        host.socket = null;
    }
}

//
// The core's quit callback: the accepting loop ends, and run destroys the core and returns.
//
fn quit(user_data: ?*anyopaque) callconv(.c) void {
    const host: *DevHost = @ptrCast(@alignCast(user_data.?));
    host.stopping.store(true, .release);
    // Accepting blocks, so a connection made here makes the loop look at the flag.
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", host.port) catch unreachable;
    if (address.connect(host.io, .{
        .mode = .stream,
    })) |stream| {
        stream.close(host.io);
    }
    else |err| {
        std.debug.panic("ziggy dev host: could not wake the accepting loop to quit: {s}", .{@errorName(err)});
    }
}

//
// The native host callback that answers the operating system's version.
//
fn osVersion(user_data: ?*anyopaque, buffer: [*c]u8, capacity: usize) callconv(.c) isize {
    _ = user_data;
    // Windows has no uname, so its version is asked of the kernel, as the Windows native app does.
    if (builtin.os.tag == .windows) {
        var windows_info = std.mem.zeroes(std.os.windows.RTL_OSVERSIONINFOW);
        windows_info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
        if (std.os.windows.ntdll.RtlGetVersion(&windows_info) != .SUCCESS) {
            return -1;
        }
        const windows_written = std.fmt.bufPrint(buffer[0..capacity], "\"Windows {d}.{d}.{d} {s}\"", .{
            windows_info.dwMajorVersion,
            windows_info.dwMinorVersion,
            windows_info.dwBuildNumber,
            @tagName(builtin.cpu.arch),
        }) catch {
            return -1;
        };
        return @intCast(windows_written.len);
    }
    var info: std.c.utsname = undefined;
    if (std.c.uname(&info) != 0) {
        return -1;
    }
    var version_buffer: [256]u8 = undefined;
    const version = std.fmt.bufPrint(&version_buffer, "{s} {s} {s}", .{
        std.mem.sliceTo(&info.sysname, 0),
        std.mem.sliceTo(&info.release, 0),
        std.mem.sliceTo(&info.machine, 0),
    }) catch {
        return -1;
    };
    // The version is written as a JSON string, so the JSON writer does the quoting and escaping.
    const written = std.fmt.bufPrint(buffer[0..capacity], "{f}", .{std.json.fmt(version, .{})}) catch {
        return -1;
    };
    return @intCast(written.len);
}

//
// The native host callback that shows a file or folder dialog and writes the paths chosen into the buffer as a JSON array. The core
// calls it from a worker thread, and the dialog is a program of its own, so it is run and waited for here.
//
fn pickPaths(user_data: ?*anyopaque, kind: i32, title: [*c]const u8, initial_name: [*c]const u8, buffer: [*c]u8, capacity: usize) callconv(.c) isize {
    const host: *DevHost = @ptrCast(@alignCast(user_data.?));
    const dialog_kind = pickers.kindFromInt(kind) orelse {
        std.debug.print("ziggy dev host: the core asked for a dialog of a kind ziggy.h does not give: {d}\n", .{kind});
        return -1;
    };
    const title_text: ?[]const u8 = if (title != null) std.mem.span(title) else null;
    const initial_name_text: ?[]const u8 = if (initial_name != null) std.mem.span(initial_name) else null;
    const json = pickers.pick(host.io, host.allocator, dialog_kind, title_text, initial_name_text) catch |err| {
        std.debug.print("ziggy dev host: the dialog failed: {s}\n", .{@errorName(err)});
        return -1;
    };
    defer host.allocator.free(json);
    if (json.len > capacity) {
        std.debug.print("ziggy dev host: the paths chosen do not fit in the {d} bytes the core gave for them\n", .{capacity});
        return -1;
    }
    @memcpy(buffer[0..json.len], json);
    return @intCast(json.len);
}

//
// Serves the requests of one connection until it closes. A request for the WebSocket turns the connection into the page's socket
// for the rest of its life.
//
fn serveConnection(host: *DevHost, stream: std.Io.net.Stream) void {
    const io = host.io;
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
                    tunnelToDevServer(host, stream, &reader.interface, &request) catch |err| {
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
                serveSocket(host, &request, key orelse "") catch |err| {
                    std.debug.print("ziggy dev host: the page's connection ended: {s}\n", .{@errorName(err)});
                };
                return;
            },
            else => {},
        }
        if (!own) {
            // The dev server's answer ends with its connection, so this connection ends after it too.
            forwardToDevServer(host, &request, &writer.interface) catch |err| {
                std.debug.print("ziggy dev host: forwarding {s} to the app's dev server failed: {s}\n", .{ request.head.target, @errorName(err) });
            };
            return;
        }
        answerRequest(host, &request) catch |err| {
            std.debug.print("ziggy dev host: a request for {s} failed: {s}\n", .{ request.head.target, @errorName(err) });
            return;
        };
    }
}

//
// Answers one ordinary request.
//
fn answerRequest(host: *DevHost, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    if (request.head.method == .POST) {
        if (std.mem.startsWith(u8, target, "/__ziggy/dropped-file?")) {
            return saveDroppedFile(host, request);
        }
        if (std.mem.eql(u8, target, "/__ziggy/drop")) {
            return recordDrop(host, request);
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
            return redirectToIndex(host, request);
        }
    }
    return request.respond("Not found\n", .{
        .status = .not_found,
    });
}

//
// Answers with a script, which the browser is told never to keep, so a reload after a rebuild gets the new one.
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
// Sends the browser to index.html with the query the app makes, as a native app loads it. A browser opened at /__ziggy/start gets
// the UI as a native app shows it, test mode switch included.
//
fn redirectToIndex(host: *DevHost, request: *std.http.Server.Request) !void {
    var query_length: usize = 0;
    const query_pointer = blk: {
        host.core_mutex.lockUncancelable(host.io);
        defer host.core_mutex.unlock(host.io);
        const core = host.core orelse {
            return error.CoreDestroyed;
        };
        break :blk z.ziggy_ui_query(core, &query_length) orelse {
            return error.UiQueryFailed;
        };
    };
    const query = query_pointer[0..query_length];
    const location = try std.fmt.allocPrint(host.allocator, "/index.html{s}{s}", .{ if (query.len > 0) "?" else "", query });
    defer host.allocator.free(location);
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
// Saves the body of the request, the contents of one dropped file, as a copy under the data directory, and answers with the copy's
// path. The name comes from the query's name parameter.
//
fn saveDroppedFile(host: *DevHost, request: *std.http.Server.Request) !void {
    const io = host.io;
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
    const drop_number = host.drop_count.fetchAdd(1, .monotonic) + 1;
    var drop_name_buffer: [64]u8 = undefined;
    const drop_name = try std.fmt.bufPrint(&drop_name_buffer, "{d}-{d}", .{ std.Io.Clock.real.now(io).toMilliseconds(), drop_number });
    const directory = try std.fs.path.join(host.allocator, &.{ host.options.data_dir, "dropped", drop_name });
    defer host.allocator.free(directory);
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const copy_path = try std.fs.path.join(host.allocator, &.{ directory, name });
    defer host.allocator.free(copy_path);
    const absolute_directory = try std.Io.Dir.cwd().realPathFileAlloc(io, directory, host.allocator);
    defer host.allocator.free(absolute_directory);
    const absolute_copy_path = try std.fs.path.join(host.allocator, &.{ absolute_directory, name });
    defer host.allocator.free(absolute_copy_path);

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
// Records a drop with the core: the body is the JSON array of the copies' paths, as a native app records the paths it read.
//
fn recordDrop(host: *DevHost, request: *std.http.Server.Request) !void {
    var body_buffer: [64 * 1024]u8 = undefined;
    const body = try request.readerExpectContinue(&body_buffer);
    const paths_json = try body.allocRemaining(host.allocator, .limited(1024 * 1024));
    defer host.allocator.free(paths_json);
    const recorded = blk: {
        host.core_mutex.lockUncancelable(host.io);
        defer host.core_mutex.unlock(host.io);
        const core = host.core orelse {
            return error.CoreDestroyed;
        };
        break :blk z.ziggy_files_dropped(core, paths_json.ptr, paths_json.len);
    };
    if (!recorded) {
        return request.respond("The core would not record the drop. The dev host's output says why.", .{
            .status = .bad_request,
        });
    }
    return request.respond("", .{
        .status = .no_content,
    });
}

//
// Forwards one request to the app's dev server and writes its answer to the browser. A page gets Ziggy's scripts on the way through,
// and anything else is passed on as it came. Answers the browser itself when the dev server cannot be reached.
//
fn forwardToDevServer(host: *DevHost, request: *std.http.Server.Request, client: *std.Io.Writer) !void {
    const io = host.io;
    const allocator = host.allocator;
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

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", host.options.ui_port);
    const upstream = address.connect(io, .{
        .mode = .stream,
    }) catch |err| {
        var message_buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "The app's dev server is not answering on 127.0.0.1:{d}: {s}", .{ host.options.ui_port, @errorName(err) }) catch "The app's dev server is not answering.";
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
// it came, and from then on bytes are copied both ways until either side closes.
//
fn tunnelToDevServer(host: *DevHost, browser: std.Io.net.Stream, browser_reader: *std.Io.Reader, request: *std.http.Server.Request) !void {
    const io = host.io;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", host.options.ui_port);
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

    const back = try std.Thread.spawn(.{}, copyToBrowser, .{ io, upstream, browser });
    copyAsItComes(browser_reader, &upstream_writer.interface) catch {};
    // The browser has gone, so the dev server's side is ended too, which ends the copy the other way.
    upstream.shutdown(io, .both) catch {};
    back.join();
}

//
// Copies what the dev server sends on a tunnelled WebSocket to the browser until either side closes.
//
fn copyToBrowser(io: std.Io, upstream: std.Io.net.Stream, browser: std.Io.net.Stream) void {
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
// Serves the page's WebSocket: every message the page sends goes to the core, until the page closes it.
//
fn serveSocket(host: *DevHost, request: *std.http.Server.Request, key: []const u8) !void {
    var socket = Socket{
        .web_socket = try request.respondWebSocket(.{
            .key = key,
        }),
    };
    try socket.web_socket.flush();
    try connectSocket(host, &socket);
    defer disconnectSocket(host, &socket);
    var pong = PongContext{
        .host = host,
        .socket = &socket,
    };
    while (true) {
        const message = web_socket_lib.readMessage(socket.web_socket.input, host.allocator, message_limit, .{
            .context = &pong,
            .answer = answerPing,
        }) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        switch (message) {
            .data => |text| {
                defer host.allocator.free(text);
                postToCore(host, text);
            },
            .close => return,
        }
    }
}

//
// What answering a ping needs: the socket to write the pong to, which only the holder of the host's socket mutex writes to.
//
const PongContext = struct {
    // The dev host.
    host: *DevHost,
    // The socket the ping came on.
    socket: *Socket,
};

//
// Answers a ping with a pong carrying its payload.
//
fn answerPing(context: *anyopaque, payload: []const u8) anyerror!void {
    const pong: *PongContext = @ptrCast(@alignCast(context));
    pong.host.socket_mutex.lockUncancelable(pong.host.io);
    defer pong.host.socket_mutex.unlock(pong.host.io);
    try pong.socket.web_socket.writeMessage(payload, .pong);
}
