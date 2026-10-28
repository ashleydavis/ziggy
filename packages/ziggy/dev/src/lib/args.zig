//
// The command lines of the dev host and of the supervisor that rebuilds and restarts it. Each option takes the next argument as
// its value, except the switches. A missing value, an unknown option or a missing required option is an error naming it.
//

const std = @import("std");

//
// What the dev host is told on its command line.
//
pub const DevHostOptions = struct {
    // The port to listen on, or 0 for one the operating system chooses.
    port: u16,
    // The file the port is written to once the dev host listens, or null for none.
    port_file: ?[]const u8,
    // The port the app's own dev server listens on, on 127.0.0.1, which every request outside /__ziggy is forwarded to.
    ui_port: u16,
    // The app's data directory.
    data_dir: []const u8,
    // The remote control server's address, "host:port", which the core connects to, or null to run without remote control.
    remote_control: ?[]const u8,
};

//
// What the supervisor is told on its command line: by the app's build, and after `--` by whoever runs it.
//
pub const SupervisorOptions = struct {
    // The Zig executable, which rebuilds the dev host.
    zig: []const u8,
    // The app's build root, where the builds run and whose Zig files are watched.
    app_dir: []const u8,
    // Ziggy's own directory, whose Zig files are watched too.
    ziggy_dir: []const u8,
    // The build step that builds the dev host.
    host_step: []const u8,
    // The name of the dev host's executable, under bin of the install prefix.
    host_name: []const u8,
    // The port the dev host listens on, or 0 for one the operating system chooses.
    port: u16,
    // The remote control server's address, "host:port", passed on to the dev host, or null to run without remote control.
    remote_control: ?[]const u8,
    // Whether the browser is left closed, for a run that drives a browser of its own.
    no_open: bool,
};

//
// Reads the dev host's command line, not counting the program's name.
//
pub fn parseDevHostOptions(args: []const []const u8) !DevHostOptions {
    var port: u16 = 0;
    var port_file: ?[]const u8 = null;
    var ui_port: ?u16 = null;
    var data_dir: ?[]const u8 = null;
    var remote_control: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const name = args[index];
        if (std.mem.eql(u8, name, "--port")) {
            port = try parsePort(try valueAfter(args, &index));
        }
        else if (std.mem.eql(u8, name, "--port-file")) {
            port_file = try valueAfter(args, &index);
        }
        else if (std.mem.eql(u8, name, "--ui-port")) {
            ui_port = try parsePort(try valueAfter(args, &index));
        }
        else if (std.mem.eql(u8, name, "--remote-control")) {
            remote_control = try valueAfter(args, &index);
        }
        else if (std.mem.eql(u8, name, "--data-dir")) {
            data_dir = try valueAfter(args, &index);
        }
        else {
            return error.UnknownOption;
        }
    }
    return .{
        .port = port,
        .port_file = port_file,
        .ui_port = ui_port orelse return error.MissingUiPort,
        .data_dir = data_dir orelse return error.MissingDataDir,
        .remote_control = remote_control,
    };
}

//
// Reads the supervisor's command line, not counting the program's name.
//
pub fn parseSupervisorOptions(args: []const []const u8) !SupervisorOptions {
    var zig: ?[]const u8 = null;
    var app_dir: ?[]const u8 = null;
    var ziggy_dir: ?[]const u8 = null;
    var host_step: ?[]const u8 = null;
    var host_name: ?[]const u8 = null;
    var port: u16 = 0;
    var no_open = false;
    var remote_control: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const name = args[index];
        if (std.mem.eql(u8, name, "--zig")) {
            zig = try valueAfter(args, &index);
        }
        else if (std.mem.eql(u8, name, "--app-dir")) {
            app_dir = try valueAfter(args, &index);
        }
        else if (std.mem.eql(u8, name, "--ziggy-dir")) {
            ziggy_dir = try valueAfter(args, &index);
        }
        else if (std.mem.eql(u8, name, "--host-step")) {
            host_step = try valueAfter(args, &index);
        }
        else if (std.mem.eql(u8, name, "--host-name")) {
            host_name = try valueAfter(args, &index);
        }
        else if (std.mem.eql(u8, name, "--port")) {
            port = try parsePort(try valueAfter(args, &index));
        }
        else if (std.mem.eql(u8, name, "--remote-control")) {
            remote_control = try valueAfter(args, &index);
        }
        else if (std.mem.eql(u8, name, "--no-open")) {
            no_open = true;
        }
        else {
            return error.UnknownOption;
        }
    }
    return .{
        .zig = zig orelse return error.MissingZig,
        .app_dir = app_dir orelse return error.MissingAppDir,
        .ziggy_dir = ziggy_dir orelse return error.MissingZiggyDir,
        .host_step = host_step orelse return error.MissingHostStep,
        .host_name = host_name orelse return error.MissingHostName,
        .port = port,
        .remote_control = remote_control,
        .no_open = no_open,
    };
}

//
// The argument after the option at the index, moving the index past it, or error.MissingValue when the option is the last.
//
fn valueAfter(args: []const []const u8, index: *usize) ![]const u8 {
    if (index.* + 1 >= args.len) {
        return error.MissingValue;
    }
    index.* += 1;
    return args[index.*];
}

//
// A port number, or error.BadPort when the text is not one.
//
fn parsePort(text: []const u8) !u16 {
    return std.fmt.parseInt(u16, text, 10) catch {
        return error.BadPort;
    };
}
