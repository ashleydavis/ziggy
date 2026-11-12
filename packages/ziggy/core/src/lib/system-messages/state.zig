//
// The system messages of the state file, the place the frontend's plain JavaScript values meet the file, carried as JSON over the
// bridge. The frontend reaches only the key paths the app opens to it.
//

const std = @import("std");
const config_state = @import("config_state");
const json = @import("../json.zig");

//
// One value to write at a key path, as set-state carries it. A null value removes the key.
//
pub const SetValueRequest = struct {
    // The dotted key path into the file's nesting.
    path: []const u8,
    // The value to write, or null to remove the key.
    value: std.json.Value = .null,
};

//
// The value at a key path of the state file, as JSON, or null when it is absent.
//
pub fn getState(
    arena: std.mem.Allocator,
    io: std.Io,
    state_file_path: ?[]const u8,
    path: []const u8,
) !json.Raw {
    const file_path = try pathFor(state_file_path);
    const value = try config_state.state.readValue(arena, io, .{ .path = file_path, .key_path = path });
    return .{ .text = try json.stringify(arena, value orelse absentValue()) };
}

//
// Writes one value at a key path of the state file. A null value removes the key.
//
pub fn setState(
    arena: std.mem.Allocator,
    io: std.Io,
    state_file_path: ?[]const u8,
    request: SetValueRequest,
) !void {
    const file_path = try pathFor(state_file_path);
    try config_state.state.writeValue(arena, io, .{ .path = file_path, .key_path = request.path }, valueOrNull(request.value));
}

//
// The path of the state file, failing with error.AppNameMissing for a core built for no app.
//
fn pathFor(state_file_path: ?[]const u8) error{AppNameMissing}![]const u8 {
    return state_file_path orelse error.AppNameMissing;
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
