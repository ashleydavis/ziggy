//
// The state file: what the app remembers on one computer, stored as nested JSON. It is read into the package's JSON values, edited through
// the typed key-path API and written back whole.
//

const std = @import("std");
const utils = @import("utils");
const errors = utils.errors;
const atomic_file = @import("atomic-file.zig");
const typed = @import("typed.zig");
const key_path = @import("key-path.zig");

//
// What was read from the state file: its values and a problem when it could not be read.
//
pub const StateRead = struct {
    // The file's values, empty when it is missing or unreadable.
    values: std.json.ObjectMap,
    // Why the file could not be read, or null when it read.
    problem: ?[]const u8,
};

//
// The most of the state file that is read, so a wrong file cannot exhaust memory.
//
pub const read_limit_bytes: u32 = 16 * 1024 * 1024;

//
// Parses the state file's text. `error.OutOfMemory` is returned as it is; any other failure gives empty values and a problem saying what
// was wrong.
//
pub fn parse(arena: std.mem.Allocator, text: []const u8) !StateRead {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{
            .values = .empty,
            .problem = try std.fmt.allocPrint(arena, "it is not JSON ({s})", .{@errorName(err)}),
        },
    };
    if (parsed != .object) {
        return .{
            .values = .empty,
            .problem = "it holds JSON that is not an object",
        };
    }
    return .{
        .values = parsed.object,
        .problem = null,
    };
}

//
// Writes the state values as JSON, indented two spaces.
//
pub fn format(arena: std.mem.Allocator, values: std.json.ObjectMap) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = values }, .{ .whitespace = .indent_2 });
}

//
// Reads the state file. A missing file is empty values and no problem; a file over `read_limit_bytes` is empty values and a problem.
//
pub fn read(arena: std.mem.Allocator, io: std.Io, path: []const u8) !StateRead {
    std.debug.assert(path.len > 0);
    const text = atomic_file.readLimited(arena, io, path, read_limit_bytes) catch |err| switch (err) {
        error.FileTooLarge => return .{
            .values = .empty,
            .problem = "the file is larger than 16 MiB",
        },
        else => return err,
    };
    const file_text = text orelse return .{
        .values = .empty,
        .problem = null,
    };
    return parse(arena, file_text);
}

//
// The values a change works on, read under the update lock.
//
pub const ChangeValues = struct {
    // The arena the change allocates in.
    arena: std.mem.Allocator,
    // The file the change works on.
    file: typed.FileKind,
    // The values the change reads and writes.
    values: *std.json.ObjectMap,
};

//
// The values a change works on, handed to it without a JSON type in the type an app is handed.
//
pub const Values = struct {
    // Points at a ChangeValues, valid only during the change's run.
    state: *anyopaque,

    //
    // Reads a value of the type the caller names.
    //
    pub fn get(self: Values, comptime T: type, key_path_text: []const u8) !T {
        const change_values = asChangeValues(self);
        const keys = try key_path.split(change_values.arena, key_path_text);
        const value = try key_path.lookup(change_values.values.*, change_values.file, keys);
        return typed.decode(T, change_values.arena, change_values.file, key_path_text, value);
    }

    //
    // Writes a value at a key path. A null removes the key.
    //
    pub fn set(self: Values, key_path_text: []const u8, value: anytype) !void {
        const change_values = asChangeValues(self);
        const encoded = try typed.encode(change_values.arena, change_values.file, key_path_text, value);
        try setRaw(self, key_path_text, encoded);
    }
};

//
// The ChangeValues behind a Values.
//
fn asChangeValues(values: Values) *ChangeValues {
    return @ptrCast(@alignCast(values.state));
}

//
// Puts a value, already converted to the files' JSON, at a key path.
//
fn setRaw(values: Values, key_path_text: []const u8, value: ?std.json.Value) !void {
    const change_values = asChangeValues(values);
    const keys = try key_path.split(change_values.arena, key_path_text);
    change_values.values.* = try key_path.put(change_values.arena, change_values.values.*, change_values.file, keys, value);
}

//
// A random version 4 UUID, which names a copy of an unreadable file so that an earlier copy is never replaced.
//
fn randomUUID(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    return generator.generate(arena, io);
}

//
// What a state update reads and writes, as a value the atomic update can call.
//
fn StateChange(comptime ChangeT: type) type {
    return struct {
        // The file's path.
        path: []const u8,
        // The caller's change.
        change: ChangeT,

        //
        // Reads the file's values, runs the change on them and returns the new text. An unreadable file's bytes are kept beside it as
        // `<file>.unreadable-<uuid>` before the change starts from empty values, so a write never drops what the file held.
        //
        pub fn run(self: *const @This(), arena: std.mem.Allocator, io: std.Io, current: ?[]const u8) ![]const u8 {
            var read_result: StateRead = .{ .values = .empty, .problem = null };
            if (current) |bytes| {
                read_result = try parse(arena, bytes);
                if (read_result.problem != null) {
                    const backup_path = try std.mem.concat(arena, u8, &.{ self.path, ".unreadable-", try randomUUID(arena, io) });
                    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = backup_path, .data = bytes });
                    read_result.values = .empty;
                }
            }
            var values = try key_path.copyObject(arena, read_result.values);
            var change_values = ChangeValues{ .arena = arena, .file = .state, .values = &values };
            try self.change.run(arena, Values{ .state = &change_values });
            return format(arena, change_values.values.*);
        }
    };
}

//
// Updates the state file: the read, every write the change makes and the rename all happen while the update lock is held.
//
pub fn updateValues(arena: std.mem.Allocator, io: std.Io, path: []const u8, change: anytype) !void {
    std.debug.assert(path.len > 0);
    const Change = StateChange(@TypeOf(change));
    try atomic_file.update(arena, io, path, .{ .limit_bytes = read_limit_bytes, .retries = 3 }, Change{ .path = path, .change = change });
}

//
// Reads the value at a key path, or null when it is absent.
//
pub fn readValue(arena: std.mem.Allocator, io: std.Io, target: key_path.KeyTarget) !?std.json.Value {
    const read_result = try read(arena, io, target.path);
    const keys = try key_path.split(arena, target.key_path);
    return key_path.lookup(read_result.values, .state, keys);
}

//
// Writes one value at a key path. A null removes the key.
//
pub fn writeValue(arena: std.mem.Allocator, io: std.Io, target: key_path.KeyTarget, value: ?std.json.Value) !void {
    const WriteChange = struct {
        // The key path to write.
        key_path: []const u8,
        // The value to write, or null to remove the key.
        value: ?std.json.Value,

        //
        // Puts the one value.
        //
        pub fn run(self: *const @This(), change_arena: std.mem.Allocator, values: Values) !void {
            _ = change_arena;
            try setRaw(values, self.key_path, self.value);
        }
    };
    try updateValues(arena, io, target.path, WriteChange{ .key_path = target.key_path, .value = value });
}

//
// Reads a value of the type the caller names.
//
pub fn get(comptime T: type, arena: std.mem.Allocator, io: std.Io, state_path: []const u8, key_path_text: []const u8) !T {
    std.debug.assert(state_path.len > 0);
    const value = try readValue(arena, io, .{ .path = state_path, .key_path = key_path_text });
    return typed.decode(T, arena, .state, key_path_text, value);
}

//
// Runs a change on the file's values under the update lock. A change is a value with `run(self, arena, values: Values) !void`; when it
// fails, nothing is written.
//
pub fn update(arena: std.mem.Allocator, io: std.Io, state_path: []const u8, change: anytype) !void {
    try updateValues(arena, io, state_path, change);
}

//
// Writes one value at a key path. A null removes the key.
//
pub fn set(arena: std.mem.Allocator, io: std.Io, state_path: []const u8, key_path_text: []const u8, value: anytype) !void {
    const SetChange = struct {
        // The key path to write.
        key_path: []const u8,
        // The value to write.
        value: @TypeOf(value),

        //
        // Writes the one value.
        //
        pub fn run(self: *const @This(), change_arena: std.mem.Allocator, values: Values) !void {
            _ = change_arena;
            try values.set(self.key_path, self.value);
        }
    };
    try update(arena, io, state_path, SetChange{ .key_path = key_path_text, .value = value });
}

//
// How the state file is, for the log line the main thread writes as it starts.
//
pub const StateStatus = union(enum) {
    // The file exists and reads.
    present,
    // The file does not exist yet.
    missing,
    // The file exists but could not be read, with the problem.
    unreadable: []const u8,
};

//
// Reports whether the state file is present, missing or unreadable.
//
pub fn status(arena: std.mem.Allocator, io: std.Io, state_path: []const u8) !StateStatus {
    std.debug.assert(state_path.len > 0);
    const text = atomic_file.readLimited(arena, io, state_path, read_limit_bytes) catch |err| switch (err) {
        error.FileTooLarge => return .{ .unreadable = "the file is larger than 16 MiB" },
        else => return err,
    };
    const file_text = text orelse return .missing;
    const read_result = try parse(arena, file_text);
    if (read_result.problem) |problem| {
        return .{ .unreadable = problem };
    }
    return .present;
}
