//
// The supervisor of Ziggy's dev mode, which an app's `<name>-dev` build step runs. It starts the app's own dev server (the app's
// `dev:ui` package script, given a port and the loopback address), builds the dev host and starts it in front of the dev server,
// and then opens the browser at the dev host, once both are ready. The browser talks only to the dev host, which serves
// /__ziggy itself and forwards everything else to the dev server, so the app's dev server needs nothing of Ziggy's.
//
// From then on it watches the Zig files of the app and of Ziggy. A change rebuilds the dev host and restarts it on the same port,
// and the page reloads by itself once the new one responds. A build that fails is reported and the dev host that is running keeps
// running, until the next change. A change to the UI is the dev server's to see and reload.
//
// It stops when the dev host stops, which is when the app quits, and stops the dev server with it. Ctrl+C stops all of them,
// because they are in the terminal's process group.
//

const std = @import("std");
const builtin = @import("builtin");
const args_lib = @import("args.zig");
const watch = @import("watch.zig");

// How long the supervisor waits between looks at the files.
const poll_interval_ms = 250;

// How long the dev host and the dev server each have to start listening.
const start_timeout_ms = 120 * 1000;

// How often the supervisor says a build is still going.
const progress_interval_ms = 5 * 1000;

//
// Everything one running supervisor owns.
//
const Supervisor = struct {
    // The Io every call uses.
    io: std.Io,
    // The allocator for everything the supervisor keeps.
    allocator: std.mem.Allocator,
    // The command line.
    options: args_lib.SupervisorOptions,
    // The app's build root.
    app_dir: std.Io.Dir,
    // Ziggy's own directory.
    ziggy_dir: std.Io.Dir,
    // The directory under the app's zig-out that holds the dev host's port file, its data and the two prefixes it is installed to.
    prefix: []const u8,
    // The app's dev server, while it runs.
    ui_server: ?std.process.Child,
    // The port the app's dev server listens on.
    ui_port: u16,
    // The prefix, of the two, that the running dev host was installed to. A build goes to the other one, because Windows refuses to
    // replace the executable of a program that is running, and the running one keeps running when the build fails.
    host_slot: u1,
    // The dev host, while it runs.
    host: ?std.process.Child,
    // The port the dev host listens on, kept across restarts so the page's address stays the same.
    port: u16,
};

//
// Runs the supervisor and returns the process's exit code.
//
pub fn run(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(allocator);
    const options = args_lib.parseSupervisorOptions(all_args[1..]) catch |err| {
        std.debug.print("ziggy dev: {s}. The supervisor is started by an app's <name>-dev build step, which gives its options.\n", .{@errorName(err)});
        return 2;
    };
    var app_dir = try std.Io.Dir.cwd().openDir(io, options.app_dir, .{
        .iterate = true,
    });
    defer app_dir.close(io);
    var ziggy_dir = try std.Io.Dir.cwd().openDir(io, options.ziggy_dir, .{
        .iterate = true,
    });
    defer ziggy_dir.close(io);

    var supervisor = Supervisor{
        .io = io,
        .allocator = allocator,
        .options = options,
        .app_dir = app_dir,
        .ziggy_dir = ziggy_dir,
        .prefix = try std.fs.path.join(allocator, &.{ options.app_dir, "zig-out", "dev" }),
        .ui_server = null,
        .ui_port = try freePort(io),
        .host_slot = 0,
        .host = null,
        .port = options.port,
    };
    defer stopUiServer(&supervisor);
    defer stopHost(&supervisor);

    try startUiServer(&supervisor);
    if (!try buildHost(&supervisor, supervisor.host_slot)) {
        return 1;
    }
    try startHost(&supervisor, supervisor.host_slot);
    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/", .{supervisor.port});
    std.debug.print("ziggy dev: the app is at {s}. Saving a Zig file rebuilds and restarts the dev host. Ctrl+C stops.\n", .{url});
    if (!options.no_open) {
        openBrowser(&supervisor, url);
    }

    var signature = try zigSignature(&supervisor);
    while (true) {
        try io.sleep(.fromMilliseconds(poll_interval_ms), .awake);
        if (!answers(io, supervisor.port)) {
            return hostExitCode(&supervisor);
        }
        const new_signature = try zigSignature(&supervisor);
        if (new_signature == signature) {
            continue;
        }
        signature = try settledSignature(&supervisor, new_signature);
        std.debug.print("ziggy dev: a Zig file changed\n", .{});
        const next_slot = 1 - supervisor.host_slot;
        if (try buildHost(&supervisor, next_slot)) {
            stopHost(&supervisor);
            supervisor.host_slot = next_slot;
            try startHost(&supervisor, next_slot);
            std.debug.print("ziggy dev: the dev host restarted, and the page reloads when it reconnects\n", .{});
        }
        else {
            std.debug.print("ziggy dev: the build failed, so the dev host that was running keeps running\n", .{});
        }
    }
}

//
// A port nothing listens on now, which the operating system chooses.
//
fn freePort(io: std.Io) !u16 {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    return listener.socket.address.getPort();
}

//
// The sum of the Zig files of the app and of Ziggy.
//
fn zigSignature(supervisor: *Supervisor) !u64 {
    const app_sum = try watch.treeSignature(supervisor.io, supervisor.allocator, supervisor.app_dir);
    const ziggy_sum = try watch.treeSignature(supervisor.io, supervisor.allocator, supervisor.ziggy_dir);
    return app_sum +% ziggy_sum *% 31;
}

//
// Waits until the sum stops changing, so that an editor saving several files at once causes one build, and returns the last sum.
//
fn settledSignature(supervisor: *Supervisor, first: u64) !u64 {
    var last = first;
    while (true) {
        try supervisor.io.sleep(.fromMilliseconds(poll_interval_ms), .awake);
        const now = try zigSignature(supervisor);
        if (now == last) {
            return now;
        }
        last = now;
    }
}

//
// Starts the app's dev server with its `dev:ui` package script, on the supervisor's port for it and the loopback address, and waits
// until it listens.
//
fn startUiServer(supervisor: *Supervisor) !void {
    const io = supervisor.io;
    var port_text: [8]u8 = undefined;
    const port_argument = try std.fmt.bufPrint(&port_text, "{d}", .{supervisor.ui_port});
    std.debug.print("ziggy dev: starting the app's dev server (bun run dev:ui) on 127.0.0.1:{d}\n", .{supervisor.ui_port});
    supervisor.ui_server = try std.process.spawn(io, .{
        .argv = &.{ "bun", "run", "dev:ui", "--port", port_argument, "--host", "127.0.0.1" },
        .cwd = .{
            .path = supervisor.options.app_dir,
        },
    });
    waitUntilListening(io, supervisor.ui_port) catch |err| {
        std.debug.print("ziggy dev: the app's dev server did not start listening on 127.0.0.1:{d}. Its output above says why. The app's package.json needs a dev:ui script that runs its bundler's dev server and takes --port and --host.\n", .{supervisor.ui_port});
        return err;
    };
}

//
// Stops the app's dev server and waits for it to end, when it runs.
//
fn stopUiServer(supervisor: *Supervisor) void {
    if (supervisor.ui_server) |*server| {
        server.kill(supervisor.io);
        supervisor.ui_server = null;
    }
}

//
// The prefix of one of the two slots the dev host is installed to.
//
fn slotPrefix(supervisor: *Supervisor, slot: u1) ![]const u8 {
    return std.fs.path.join(supervisor.allocator, &.{ supervisor.prefix, if (slot == 0) "host-a" else "host-b" });
}

//
// Builds the dev host into the prefix of the slot, in the app's build root, saying every few seconds that it is still building. Says whether
// it built.
//
fn buildHost(supervisor: *Supervisor, slot: u1) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(supervisor.allocator);
    try argv.appendSlice(supervisor.allocator, &.{ supervisor.options.zig, "build", supervisor.options.host_step, "-p", try slotPrefix(supervisor, slot) });
    if (supervisor.options.test_hooks) {
        try argv.append(supervisor.allocator, "-Dtest-hooks=true");
    }
    std.debug.print("ziggy dev: building the dev host. The first build compiles the whole core and takes the longest.\n", .{});
    var child = std.process.spawn(supervisor.io, .{
        .argv = argv.items,
        .cwd = .{
            .path = supervisor.options.app_dir,
        },
    }) catch |err| {
        std.debug.print("ziggy dev: could not run {s}: {s}\n", .{ supervisor.options.zig, @errorName(err) });
        return false;
    };
    var finished: std.atomic.Value(bool) = .init(false);
    const progress = try std.Thread.spawn(.{}, reportProgress, .{ supervisor.io, &finished });
    const term = child.wait(supervisor.io);
    finished.store(true, .release);
    progress.join();
    const built = switch (try term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (built) {
        std.debug.print("ziggy dev: the dev host is built\n", .{});
    }
    return built;
}

//
// Says how long the build has been going, every few seconds, until it has finished.
//
fn reportProgress(io: std.Io, finished: *std.atomic.Value(bool)) void {
    const started = std.Io.Clock.awake.now(io);
    var next_report_ms: i64 = progress_interval_ms;
    while (!finished.load(.acquire)) {
        io.sleep(.fromMilliseconds(poll_interval_ms), .awake) catch {
            return;
        };
        const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
        if (elapsed_ms >= next_report_ms and !finished.load(.acquire)) {
            std.debug.print("ziggy dev: still building the dev host ({d}s)\n", .{@divTrunc(elapsed_ms, 1000)});
            next_report_ms += progress_interval_ms;
        }
    }
}

//
// Starts the dev host on the supervisor's port, or on one the operating system chooses the first time when none was given, in
// front of the app's dev server, and waits until it says which port it listens on.
//
fn startHost(supervisor: *Supervisor, slot: u1) !void {
    const io = supervisor.io;
    const allocator = supervisor.allocator;
    const executable_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ supervisor.options.host_name, builtin.target.exeFileExt() });
    const executable = try std.fs.path.join(allocator, &.{ try slotPrefix(supervisor, slot), "bin", executable_name });
    const port_file = try std.fs.path.join(allocator, &.{ supervisor.prefix, "port.txt" });
    const data_dir = try std.fs.path.join(allocator, &.{ supervisor.prefix, "data" });
    var port_text: [8]u8 = undefined;
    const port_argument = try std.fmt.bufPrint(&port_text, "{d}", .{supervisor.port});
    var ui_port_text: [8]u8 = undefined;
    const ui_port_argument = try std.fmt.bufPrint(&ui_port_text, "{d}", .{supervisor.ui_port});

    std.Io.Dir.cwd().deleteFile(io, port_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    supervisor.host = try std.process.spawn(io, .{
        .argv = &.{ executable, "--port", port_argument, "--port-file", port_file, "--ui-port", ui_port_argument, "--data-dir", data_dir },
    });

    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(start_timeout_ms));
    while (true) {
        var read_buffer: [16]u8 = undefined;
        if (std.Io.Dir.cwd().readFile(io, port_file, &read_buffer)) |text| {
            if (text.len > 0) {
                supervisor.port = try std.fmt.parseInt(u16, std.mem.trim(u8, text, " \r\n"), 10);
                return;
            }
        }
        else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        if (std.Io.Clock.awake.now(io).durationTo(deadline).nanoseconds <= 0) {
            return error.DevHostDidNotStart;
        }
        try io.sleep(.fromMilliseconds(50), .awake);
    }
}

//
// Stops the dev host and waits for it to end, when it runs.
//
fn stopHost(supervisor: *Supervisor) void {
    if (supervisor.host) |*host| {
        host.kill(supervisor.io);
        supervisor.host = null;
    }
}

//
// Whether something accepts connections on the loopback port.
//
fn answers(io: std.Io, port: u16) bool {
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    const stream = address.connect(io, .{
        .mode = .stream,
    }) catch {
        return false;
    };
    stream.close(io);
    return true;
}

//
// Waits until something accepts connections on the loopback port, or fails when nothing has within the start timeout.
//
fn waitUntilListening(io: std.Io, port: u16) !void {
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(start_timeout_ms));
    while (!answers(io, port)) {
        if (std.Io.Clock.awake.now(io).durationTo(deadline).nanoseconds <= 0) {
            return error.NotListening;
        }
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

//
// Waits for the dev host that stopped responding to end and returns its exit code.
//
fn hostExitCode(supervisor: *Supervisor) !u8 {
    var host = supervisor.host orelse {
        return error.DevHostNotRunning;
    };
    supervisor.host = null;
    const term = try host.wait(supervisor.io);
    std.debug.print("ziggy dev: the dev host stopped\n", .{});
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

//
// Opens the page in the desktop's default browser. A failure is reported and the supervisor carries on, because the address it
// printed can be opened in a browser.
//
fn openBrowser(supervisor: *Supervisor, url: []const u8) void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "cmd", "/c", "start", "", url },
        .macos => &.{ "open", url },
        else => &.{ "xdg-open", url },
    };
    var child = std.process.spawn(supervisor.io, .{
        .argv = argv,
    }) catch |err| {
        std.debug.print("ziggy dev: could not open the browser ({s}): {s}\n", .{ argv[0], @errorName(err) });
        return;
    };
    _ = child.wait(supervisor.io) catch |err| {
        std.debug.print("ziggy dev: the browser opener did not finish: {s}\n", .{@errorName(err)});
    };
}
