//
// The conversion between the values a config or state file holds and the app's Zig types, so no TOML or JSON type ever reaches an app.
//

const std = @import("std");
const utils = @import("utils");
const errors = utils.errors;

//
// Which of the two files a function works on, used in every message that names one.
//
pub const FileKind = enum {
    config,
    state,
};

//
// Reads a value of the type the caller names from a value read out of a file, failing with `error.SettingWrongType` when the value is
// present but cannot be that type, and with `error.Thrown` when a value the type needs is absent.
//
pub fn decode(
    comptime T: type,
    arena: std.mem.Allocator,
    file: FileKind,
    key_path: []const u8,
    value: ?std.json.Value,
) !T {
    switch (@typeInfo(T)) {
        .bool => {
            const found = value orelse return absent(T, file, key_path);
            if (found != .bool) {
                return wrongKind(T, file, key_path, found);
            }
            return found.bool;
        },
        .int => {
            const found = value orelse return absent(T, file, key_path);
            if (found != .integer) {
                return wrongKind(T, file, key_path, found);
            }
            return std.math.cast(T, found.integer) orelse {
                errors.recordError("Error", "The {s} setting \"{s}\" holds the integer {d}, which is outside the range of {s}.", .{ @tagName(file), key_path, found.integer, @typeName(T) });
                return error.SettingWrongType;
            };
        },
        .float => {
            const found = value orelse return absent(T, file, key_path);
            return switch (found) {
                .float => |number| @floatCast(number),
                .integer => |number| @floatFromInt(number),
                else => wrongKind(T, file, key_path, found),
            };
        },
        .pointer => |pointer| {
            if (pointer.size == .slice and pointer.child == u8) {
                const found = value orelse return absent(T, file, key_path);
                if (found != .string) {
                    return wrongKind(T, file, key_path, found);
                }
                return try arena.dupe(u8, found.string);
            }
            if (pointer.size == .slice) {
                const found = value orelse return absent(T, file, key_path);
                if (found != .array) {
                    return wrongKind(T, file, key_path, found);
                }
                const items = try arena.alloc(pointer.child, found.array.items.len);
                for (found.array.items, 0..) |item, index| {
                    items[index] = try decode(pointer.child, arena, file, try indexedKeyPath(arena, key_path, index), item);
                }
                return items;
            }
            return unsupported(T);
        },
        .@"enum" => {
            const found = value orelse return absent(T, file, key_path);
            if (found != .string) {
                return wrongKind(T, file, key_path, found);
            }
            return std.meta.stringToEnum(T, found.string) orelse {
                errors.recordError("Error", "The {s} setting \"{s}\" holds the string \"{s}\", which is no {s}.", .{ @tagName(file), key_path, found.string, @typeName(T) });
                return error.SettingWrongType;
            };
        },
        .optional => |optional| {
            if (value == null or value.? == .null) {
                return null;
            }
            return try decode(optional.child, arena, file, key_path, value);
        },
        .array => |array| {
            const found = value orelse return absent(T, file, key_path);
            if (found != .array) {
                return wrongKind(T, file, key_path, found);
            }
            if (found.array.items.len != array.len) {
                errors.recordError("Error", "The {s} setting \"{s}\" holds a list of {d}, and the app asked for an array of {d}.", .{ @tagName(file), key_path, found.array.items.len, array.len });
                return error.SettingWrongType;
            }
            var result: T = undefined;
            for (found.array.items, 0..) |item, index| {
                result[index] = try decode(array.child, arena, file, try indexedKeyPath(arena, key_path, index), item);
            }
            return result;
        },
        .@"struct" => |structure| {
            if (value == null) {
                return absent(T, file, key_path);
            }
            if (value.? != .object) {
                return wrongKind(T, file, key_path, value.?);
            }
            const object = value.?.object;
            var result: T = undefined;
            inline for (structure.fields) |field| {
                const field_path = try extendedKeyPath(arena, key_path, field.name);
                if (object.get(field.name)) |field_value| {
                    @field(result, field.name) = try decode(field.type, arena, file, field_path, field_value);
                }
                else if (field.default_value_ptr) |default_value_ptr| {
                    @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(default_value_ptr))).*;
                }
                else if (@typeInfo(field.type) == .optional) {
                    @field(result, field.name) = null;
                }
                else {
                    return absent(field.type, file, field_path);
                }
            }
            return result;
        },
        else => return unsupported(T),
    }
}

//
// Converts a value of the type the caller gives into the value a file holds, or null when a null removes the key.
//
pub fn encode(
    arena: std.mem.Allocator,
    file: FileKind,
    key_path: []const u8,
    value: anytype,
) !?std.json.Value {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .null => return null,
        .bool => return .{ .bool = value },
        .int, .comptime_int => {
            const number = std.math.cast(i64, value) orelse return errors.throwError(
                "The {s} setting \"{s}\" cannot hold the integer {d} of type {s}: a file holds no integer wider than i64.",
                .{ @tagName(file), key_path, value, @typeName(T) },
            );
            return .{ .integer = number };
        },
        .float, .comptime_float => {
            const number: f64 = @floatCast(value);
            if (file == .state and !std.math.isFinite(number)) {
                return errors.throwError("The state setting \"{s}\" cannot hold a float that is not finite.", .{key_path});
            }
            return .{ .float = number };
        },
        .pointer => |pointer| {
            if (pointer.size == .slice and pointer.child == u8) {
                return .{ .string = try arena.dupe(u8, value) };
            }
            if (pointer.size == .slice) {
                var result: std.json.Array = .init(arena);
                for (value, 0..) |item, index| {
                    const encoded = try encode(arena, file, try indexedKeyPath(arena, key_path, index), item);
                    try result.append(encoded orelse .null);
                }
                return .{ .array = result };
            }
            if (pointer.size == .one and @typeInfo(pointer.child) == .array) {
                if (@typeInfo(pointer.child).array.child == u8) {
                    const text: []const u8 = value;
                    return .{ .string = try arena.dupe(u8, text) };
                }
                var result: std.json.Array = .init(arena);
                for (value, 0..) |item, index| {
                    const encoded = try encode(arena, file, try indexedKeyPath(arena, key_path, index), item);
                    try result.append(encoded orelse .null);
                }
                return .{ .array = result };
            }
            return unsupported(T);
        },
        .@"enum" => return .{ .string = @tagName(value) },
        .optional => {
            if (value) |inner| {
                return try encode(arena, file, key_path, inner);
            }
            return null;
        },
        .array => {
            var result: std.json.Array = .init(arena);
            for (value, 0..) |item, index| {
                const encoded = try encode(arena, file, try indexedKeyPath(arena, key_path, index), item);
                try result.append(encoded orelse .null);
            }
            return .{ .array = result };
        },
        .@"struct" => |structure| {
            var object: std.json.ObjectMap = .empty;
            inline for (structure.fields) |field| {
                const encoded = try encode(arena, file, try extendedKeyPath(arena, key_path, field.name), @field(value, field.name));
                if (encoded) |encoded_value| {
                    // A null field is left out: TOML has no null.
                    if (encoded_value != .null) {
                        try object.put(arena, field.name, encoded_value);
                    }
                }
            }
            return .{ .object = object };
        },
        else => return unsupported(T),
    }
}

//
// What a value in a file is, as a message names it.
//
pub fn kindName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "a boolean",
        .integer => "an integer",
        .float => "a float",
        .number_string => "a number",
        .string => "a string",
        .array => "a list",
        .object => "a table",
    };
}

//
// Fails when a value the type needs is absent.
//
fn absent(comptime T: type, file: FileKind, key_path: []const u8) errors.ThrownError {
    return errors.throwError("The {s} setting \"{s}\" is not set, and {s} cannot be absent.", .{ @tagName(file), key_path, @typeName(T) });
}

//
// Records the message of a value of the wrong kind and fails with `error.SettingWrongType`.
//
fn wrongKind(comptime T: type, file: FileKind, key_path: []const u8, found: std.json.Value) error{SettingWrongType} {
    errors.recordError("Error", "The {s} setting \"{s}\" holds {s}, and the app asked for {s}.", .{ @tagName(file), key_path, kindName(found), @typeName(T) });
    return error.SettingWrongType;
}

//
// A type no file can hold, as a compile error naming the type.
//
fn unsupported(comptime T: type) noreturn {
    @compileError("A value of the type " ++ type_name(T) ++ " cannot be stored in a config or state file. Use a bool, an integer, a float, a string, an enum, an optional, a slice, an array or a struct.");
}

//
// The name a message gives a type. Zig's own types are named by their standard library module, so std.json.Value is named as an app names
// it rather than as the compiler shortens it.
//
fn type_name(comptime T: type) []const u8 {
    if (T == std.json.Value) {
        return "std.json.Value";
    }
    return @typeName(T);
}

//
// The key path of a struct field.
//
pub fn extendedKeyPath(arena: std.mem.Allocator, key_path: []const u8, key: []const u8) ![]const u8 {
    std.debug.assert(key.len > 0);
    if (key_path.len == 0) {
        return arena.dupe(u8, key);
    }
    return std.mem.concat(arena, u8, &.{ key_path, ".", key });
}

//
// The key path of a list element.
//
fn indexedKeyPath(arena: std.mem.Allocator, key_path: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}[{d}]", .{ key_path, index });
}
