//
// The system messages of the config file, the place the frontend's plain JavaScript values meet the file, carried as JSON over the
// bridge. The frontend reaches only the key paths the app opens to it.
//

const std = @import("std");
const config_state = @import("config_state");
const json = @import("../json.zig");

//
// One value to write at a key path, as set-config carries it. A null value removes the key.
//
pub const SetValueRequest = struct {
    // The dotted key path into the file's nesting.
    path: []const u8,
    // The value to write, or null to remove the key.
    value: std.json.Value = .null,
};

//
// The value at a key path of the config file, as JSON, or null when it is absent.
//
pub fn getConfig(
    arena: std.mem.Allocator,
    io: std.Io,
    config_file_path: ?[]const u8,
    path: []const u8,
) !json.Raw {
    const file_path = try pathFor(config_file_path);
    const value = try config_state.config.readValue(arena, io, .{ .path = file_path, .key_path = path });
    return .{ .text = try json.stringify(arena, value orelse absentValue()) };
}

//
// Writes one value at a key path of the config file. A null value removes the key. A file with a bad line is logged and left alone.
//
pub fn setConfig(
    arena: std.mem.Allocator,
    io: std.Io,
    log: @import("log").ILog,
    config_file_path: ?[]const u8,
    request: SetValueRequest,
) !void {
    const file_path = try pathFor(config_file_path);
    config_state.config.writeValue(arena, io, .{ .path = file_path, .key_path = request.path }, valueOrNull(request.value)) catch |err| switch (err) {
        error.ConfigFileInvalid => {
            if (try config_state.config.problem(arena, io, file_path)) |problem| {
                log.@"error"(try std.fmt.allocPrint(arena, "The config file {s} has an error on line {d}, column {d}: {s}. The file is left as it is.", .{ file_path, problem.line, problem.column, problem.reason }));
            }
            return err;
        },
        else => return err,
    };
}

//
// The problem with a line of the config file, or null when it reads or is missing.
//
pub fn getConfigProblem(arena: std.mem.Allocator, io: std.Io, config_file_path: ?[]const u8) !?config_state.config.ConfigProblem {
    return config_state.config.problem(arena, io, try pathFor(config_file_path));
}

//
// The path of the config file, failing with error.AppNameMissing for a core built for no app.
//
fn pathFor(config_file_path: ?[]const u8) error{AppNameMissing}![]const u8 {
    return config_file_path orelse error.AppNameMissing;
}

//
// The value written for a request: a JSON null removes the key.
//
fn valueOrNull(value: std.json.Value) ?std.json.Value {
    if (value == .null) {
        return null;
    }
    return value;
}

//
// The value a get replies with when nothing is stored at the key path.
//
fn absentValue() std.json.Value {
    return .null;
}
