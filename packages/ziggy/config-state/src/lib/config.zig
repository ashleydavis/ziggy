//
// The config file: what the user chose, stored as TOML. It is read into the package's JSON values, edited through the typed key-path API and
// written back with the file's comments and layout kept.
//

const std = @import("std");
const toml = @import("toml");
const utils = @import("utils");
const errors = utils.errors;
const atomic_file = @import("atomic-file.zig");
const typed = @import("typed.zig");
const key_path = @import("key-path.zig");
const json_toml = @import("json-toml.zig");

//
// A line of the config file that could not be read, and why.
//
pub const ConfigProblem = struct {
    // The config file's path.
    path: []const u8,
    // The line the problem starts on, counted from 1.
    line: u32,
    // The column of that line, counted from 1.
    column: u32,
    // What the TOML library said was wrong.
    reason: []const u8,
};

//
// What was read from the config file: its values, a problem with a line of it when it has one, and its text.
//
pub const ConfigRead = struct {
    // The file's values, empty when it is missing or has a problem.
    values: std.json.ObjectMap,
    // The first problem with a line of the file, or null when every line read.
    problem: ?ConfigProblem,
    // The file's text, empty when it is missing.
    text: []const u8,
};

//
// The most of the config file that is read, so a wrong file cannot exhaust memory.
//
pub const read_limit_bytes: u32 = 1024 * 1024;

//
// The two strings `parse` works from, as a struct so that they cannot be swapped.
//
pub const ParseInput = struct {
    // The config file's path, which a problem names.
    path: []const u8,
    // The file's text.
    text: []const u8,
};

//
// Parses the config file's text. `error.OutOfMemory` is returned as it is and never becomes a problem; every other failure gives empty
// values and a problem naming the first bad line and what was wrong with it.
//
pub fn parse(arena: std.mem.Allocator, input: ParseInput) !ConfigRead {
    std.debug.assert(input.path.len > 0);
    var diagnostics: std.ArrayList(toml.Diagnostic) = .empty;
    var spans: toml.Spans = .empty;
    const table = toml.parse(arena, input.text, .{ .errors = &diagnostics, .spans = &spans }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.TomlParseError, error.NestingTooDeep => {
            if (diagnostics.items.len > 0) {
                const diagnostic = diagnostics.items[0];
                const line_col = diagnostic.span.lineCol(input.text);
                return .{
                    .values = .empty,
                    .problem = .{
                        .path = input.path,
                        .line = line_col.line,
                        .column = line_col.col,
                        .reason = diagnostic.message,
                    },
                    .text = input.text,
                };
            }
            return .{
                .values = .empty,
                .problem = .{
                    .path = input.path,
                    .line = 1,
                    .column = 1,
                    .reason = @errorName(err),
                },
                .text = input.text,
            };
        },
    };
    return .{
        .values = try json_toml.tomlToJson(arena, input.text, table, &spans),
        .problem = null,
        .text = input.text,
    };
}

//
// Reads the config file. A missing file is empty values and no problem; a file over `read_limit_bytes` is a problem on line 1.
//
pub fn read(arena: std.mem.Allocator, io: std.Io, path: []const u8) !ConfigRead {
    std.debug.assert(path.len > 0);
    const text = atomic_file.readLimited(arena, io, path, read_limit_bytes) catch |err| switch (err) {
        error.FileTooLarge => return .{
            .values = .empty,
            .problem = .{
                .path = path,
                .line = 1,
                .column = 1,
                .reason = "the file is larger than 1 MiB",
            },
            .text = "",
        },
        else => return err,
    };
    const file_text = text orelse "";
    if (text == null) {
        return .{
            .values = .empty,
            .problem = null,
            .text = "",
        };
    }
    return parse(arena, .{ .path = path, .text = file_text });
}

//
// The text `edit` works from: the file's old and new values, as a struct so that the two sets cannot be swapped.
//
pub const EditInput = struct {
    // The file's text as it was read.
    text: []const u8,
    // The values the text parses to.
    old_values: std.json.ObjectMap,
    // The values to write.
    new_values: std.json.ObjectMap,
};

//
// Writes the new values while keeping the file's comments and layout. When the document cannot make an edit, or the text it writes does not
// parse back to the new values, the whole file is written in sorted key order without comments instead.
//
pub fn edit(arena: std.mem.Allocator, input: EditInput) ![]const u8 {
    return editDocument(arena, input) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return editWholeFile(arena, input.new_values),
    };
}

//
// Edits the document in place, keeping its comments and layout, and checks that the result parses to the new values.
//
fn editDocument(arena: std.mem.Allocator, input: EditInput) ![]const u8 {
    var document = if (input.text.len == 0)
        try toml.Document.empty(arena, .{})
    else
        try toml.Document.parse(arena, input.text, .{});
    try applyValues(arena, &document, input.old_values, input.new_values, &.{});

    var allocating: std.Io.Writer.Allocating = .init(arena);
    defer allocating.deinit();
    try document.emit(&allocating.writer);
    // The allocating writer frees its buffer when it is deinitialized, and an arena gives the most recent allocation back, so the text
    // is copied out before the defer runs.
    const text = try arena.dupe(u8, allocating.written());

    var spans: toml.Spans = .empty;
    const values = toml.parse(arena, text, .{ .spans = &spans }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.EditDidNotVerify,
    };
    const written_values = json_toml.tomlToJson(arena, text, values, &spans) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.EditDidNotVerify,
    };
    if (!json_toml.jsonEqual(.{ .object = written_values }, .{ .object = input.new_values })) {
        return error.EditDidNotVerify;
    }
    return text;
}

//
// Writes the whole file from the new values, in sorted key order and without comments.
//
fn editWholeFile(arena: std.mem.Allocator, values: std.json.ObjectMap) ![]const u8 {
    var allocating: std.Io.Writer.Allocating = .init(arena);
    defer allocating.deinit();
    try toml.encode(&allocating.writer, try json_toml.jsonToToml(arena, values), .{ .sort_keys = true });
    return arena.dupe(u8, allocating.written());
}

//
// Applies the difference between the old and new values to the document one key at a time.
//
fn applyValues(
    arena: std.mem.Allocator,
    document: *toml.Document,
    old_values: std.json.ObjectMap,
    new_values: std.json.ObjectMap,
    prefix: []const []const u8,
) !void {
    var old_iterator = old_values.iterator();
    while (old_iterator.next()) |entry| {
        if (new_values.get(entry.key_ptr.*) == null) {
            if (isArrayOfTables(entry.value_ptr.*)) {
                return error.ArrayOfTablesChanged;
            }
            const segments = try extendedSegments(arena, prefix, entry.key_ptr.*);
            document.removeSegments(segments) catch |err| switch (err) {
                error.PathNotFound => {},
                error.OutOfMemory => return err,
                else => return err,
            };
        }
    }

    var new_iterator = new_values.iterator();
    while (new_iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const new_value = entry.value_ptr.*;
        const old_value: ?std.json.Value = old_values.get(key);
        if (old_value) |found| {
            if (json_toml.jsonEqual(found, new_value)) {
                continue;
            }
        }
        if (!json_toml.jsonEqual(old_value orelse .null, new_value)) {
            if (isArrayOfTables(new_value) or (old_value != null and isArrayOfTables(old_value.?))) {
                return error.ArrayOfTablesChanged;
            }
        }
        const segments = try extendedSegments(arena, prefix, key);
        switch (new_value) {
            .object => |new_object| {
                if (old_value) |found| {
                    if (found != .object) {
                        try removeIgnoringMissing(document, segments);
                    }
                }
                const old_object = if (old_value) |found|
                    if (found == .object) found.object else std.json.ObjectMap.empty
                else
                    std.json.ObjectMap.empty;
                try applyValues(arena, document, old_object, new_object, segments);
            },
            else => {
                if (old_value) |found| {
                    if (found == .object) {
                        try removeIgnoringMissing(document, segments);
                    }
                }
                try document.setValueSegments(segments, try json_toml.jsonValueToToml(arena, new_value, try segmentsText(arena, segments)));
            },
        }
    }
}

//
// Removes a key, ignoring one the document does not have.
//
fn removeIgnoringMissing(document: *toml.Document, segments: []const []const u8) !void {
    document.removeSegments(segments) catch |err| switch (err) {
        error.PathNotFound => {},
        else => return err,
    };
}

//
// Whether a value is a non-empty array whose elements are all tables, which the document cannot edit.
//
fn isArrayOfTables(value: std.json.Value) bool {
    if (value != .array) {
        return false;
    }
    if (value.array.items.len == 0) {
        return false;
    }
    for (value.array.items) |item| {
        if (item != .object) {
            return false;
        }
    }
    return true;
}

//
// The segments of a key path with one more key at the end.
//
fn extendedSegments(arena: std.mem.Allocator, prefix: []const []const u8, key: []const u8) ![]const []const u8 {
    std.debug.assert(key.len > 0);
    const segments = try arena.alloc([]const u8, prefix.len + 1);
    @memcpy(segments[0..prefix.len], prefix);
    segments[prefix.len] = key;
    return segments;
}

//
// A key path's text, for a message about one of its values.
//
fn segmentsText(arena: std.mem.Allocator, segments: []const []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (segments, 0..) |segment, index| {
        if (index > 0) {
            try result.append(arena, '.');
        }
        try result.appendSlice(arena, segment);
    }
    return result.items;
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

    //
    // The arena the change allocates in, for a change that must convert a value before it sets it.
    //
    pub fn arena(self: Values) std.mem.Allocator {
        return asChangeValues(self).arena;
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
// What a config update reads and writes, as a value the atomic update can call.
//
fn ConfigChange(comptime ChangeT: type) type {
    return struct {
        // The file's path.
        path: []const u8,
        // The caller's change.
        change: ChangeT,

        //
        // Reads the file's values, runs the change on them and returns the new text.
        //
        pub fn run(self: *const @This(), arena: std.mem.Allocator, io: std.Io, current: ?[]const u8) ![]const u8 {
            _ = io;
            const read_result = try parse(arena, .{ .path = self.path, .text = current orelse "" });
            if (read_result.problem != null) {
                return error.ConfigFileInvalid;
            }
            var values = try key_path.copyObject(arena, read_result.values);
            var change_values = ChangeValues{ .arena = arena, .file = .config, .values = &values };
            try self.change.run(arena, Values{ .state = &change_values });
            return edit(arena, .{ .text = read_result.text, .old_values = read_result.values, .new_values = change_values.values.* });
        }
    };
}

//
// Updates the config file: the read, every write the change makes and the rename all happen while the update lock is held, so every write
// a change makes lands in one rename and a reader never sees part of it.
//
pub fn updateValues(arena: std.mem.Allocator, io: std.Io, path: []const u8, change: anytype) !void {
    std.debug.assert(path.len > 0);
    const Change = ConfigChange(@TypeOf(change));
    try atomic_file.update(arena, io, path, .{ .limit_bytes = read_limit_bytes, .retries = 3 }, Change{ .path = path, .change = change });
}

//
// Reads the value at a key path, or null when it is absent. A file with a problem reads as empty values.
//
pub fn readValue(arena: std.mem.Allocator, io: std.Io, target: key_path.KeyTarget) !?std.json.Value {
    const read_result = try read(arena, io, target.path);
    const keys = try key_path.split(arena, target.key_path);
    return key_path.lookup(read_result.values, .config, keys);
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
pub fn get(comptime T: type, arena: std.mem.Allocator, io: std.Io, config_path: []const u8, key_path_text: []const u8) !T {
    std.debug.assert(config_path.len > 0);
    const value = try readValue(arena, io, .{ .path = config_path, .key_path = key_path_text });
    return typed.decode(T, arena, .config, key_path_text, value);
}

//
// Whether a key path has a value, for telling whether a table exists without decoding it.
//
pub fn has(arena: std.mem.Allocator, io: std.Io, config_path: []const u8, key_path_text: []const u8) !bool {
    std.debug.assert(config_path.len > 0);
    return (try readValue(arena, io, .{ .path = config_path, .key_path = key_path_text })) != null;
}

//
// Runs a change on the file's values under the update lock. A change is a value with `run(self, arena, values: Values) !void`; when it
// fails, nothing is written.
//
pub fn update(arena: std.mem.Allocator, io: std.Io, config_path: []const u8, change: anytype) !void {
    try updateValues(arena, io, config_path, change);
}

//
// Writes one value at a key path. A null removes the key.
//
pub fn set(arena: std.mem.Allocator, io: std.Io, config_path: []const u8, key_path_text: []const u8, value: anytype) !void {
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
    try update(arena, io, config_path, SetChange{ .key_path = key_path_text, .value = value });
}

//
// The problem with a line of the config file, or null when it reads or is missing.
//
pub fn problem(arena: std.mem.Allocator, io: std.Io, config_path: []const u8) !?ConfigProblem {
    std.debug.assert(config_path.len > 0);
    return (try read(arena, io, config_path)).problem;
}
