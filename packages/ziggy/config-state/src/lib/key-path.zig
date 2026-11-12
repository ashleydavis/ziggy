//
// Dotted key paths into the nesting of a config or state file: splitting one into its keys, reading the value at one, and writing one while
// keeping every other key.
//

const std = @import("std");
const utils = @import("utils");
const errors = utils.errors;
const typed = @import("typed.zig");

//
// One key of one file, as every internal function that names it takes it, so the path and the key path cannot be swapped.
//
pub const KeyTarget = struct {
    // The file's path.
    path: []const u8,
    // The dotted key path into the file's nesting.
    key_path: []const u8,
};

//
// Splits a dotted key path into its keys, failing with a message naming the path when it is empty or has an empty key.
//
pub fn split(arena: std.mem.Allocator, key_path: []const u8) ![]const []const u8 {
    if (key_path.len == 0) {
        return errors.throwError("The key path is empty: a key path names at least one key.", .{});
    }
    var keys: std.ArrayList([]const u8) = .empty;
    var rest = key_path;
    while (true) {
        const dot = std.mem.indexOfScalar(u8, rest, '.');
        const key = if (dot) |index| rest[0..index] else rest;
        if (key.len == 0) {
            return errors.throwError("The key path \"{s}\" has an empty key.", .{key_path});
        }
        try keys.append(arena, key);
        if (dot == null) {
            break;
        }
        rest = rest[dot.? + 1 ..];
    }
    return keys.items;
}

//
// A shallow copy of a file's values, which a change can read and write without touching the values it was read from.
//
pub fn copyObject(arena: std.mem.Allocator, values: std.json.ObjectMap) !std.json.ObjectMap {
    var result: std.json.ObjectMap = .empty;
    try result.ensureTotalCapacity(arena, values.count());
    var iterator = values.iterator();
    while (iterator.next()) |entry| {
        result.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
    }
    return result;
}

//
// The value at a key path, or null when a key along the way is absent. A key whose value is not a table fails with a message naming the key
// path up to it, the table the walk needed and the kind it found.
//
pub fn lookup(values: std.json.ObjectMap, file: typed.FileKind, keys: []const []const u8) !?std.json.Value {
    std.debug.assert(keys.len > 0);
    var current = std.json.Value{ .object = values };
    for (keys, 0..) |key, index| {
        const found = current.object.get(key) orelse return null;
        if (index == keys.len - 1) {
            return found;
        }
        if (found != .object) {
            return wrongKind(file, keys, index, found);
        }
        current = found;
    }
    return null;
}

//
// A copy of a file's values with the value at the key path, copying only the tables along the path. A null removes the last key. A missing
// table along the way is created, and a key along the way whose value is not a table fails with a message naming the key path up to it.
//
pub fn put(
    arena: std.mem.Allocator,
    values: std.json.ObjectMap,
    file: typed.FileKind,
    keys: []const []const u8,
    value: ?std.json.Value,
) !std.json.ObjectMap {
    std.debug.assert(keys.len > 0);
    return putAt(arena, values, file, keys, 0, value);
}

//
// Puts a value at one key of the path, with the keys before it already walked.
//
fn putAt(
    arena: std.mem.Allocator,
    values: std.json.ObjectMap,
    file: typed.FileKind,
    keys: []const []const u8,
    index: usize,
    value: ?std.json.Value,
) !std.json.ObjectMap {
    std.debug.assert(index < keys.len);
    const key = keys[index];
    var result: std.json.ObjectMap = .empty;
    try result.ensureTotalCapacity(arena, values.count());

    if (index == keys.len - 1) {
        var iterator = values.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                continue;
            }
            result.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
        }
        if (value) |new_value| {
            try result.put(arena, key, new_value);
        }
        return result;
    }

    var found: ?std.json.Value = null;
    var iterator = values.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, key)) {
            found = entry.value_ptr.*;
            continue;
        }
        result.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
    }
    if (found) |found_value| {
        if (found_value != .object) {
            return wrongKind(file, keys, index, found_value);
        }
        const child = try putAt(arena, found_value.object, file, keys, index + 1, value);
        // A removal that empties a table removes the table too, so clearing the last key of a section leaves no empty section.
        if (value == null and child.count() == 0) {
            return result;
        }
        try result.put(arena, key, .{ .object = child });
    }
    else {
        const child = try putAt(arena, .empty, file, keys, index + 1, value);
        if (value == null and child.count() == 0) {
            return result;
        }
        try result.put(arena, key, .{ .object = child });
    }
    return result;
}

//
// Fails with a message naming the key path up to the key that is not a table.
//
fn wrongKind(file: typed.FileKind, keys: []const []const u8, index: usize, found: std.json.Value) errors.ThrownError {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    for (keys[0 .. index + 1], 0..) |key, key_index| {
        if (key_index > 0) {
            writer.writeByte('.') catch break;
        }
        writer.writeAll(key) catch break;
    }
    return errors.throwError(
        "The {s} setting \"{s}\" holds {s}, and the app asked for a table.",
        .{ @tagName(file), writer.buffered(), typed.kindName(found) },
    );
}
