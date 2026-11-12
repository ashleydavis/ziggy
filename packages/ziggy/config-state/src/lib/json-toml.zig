//
// The conversion between the TOML library's values and the JSON values the package works in internally. Dates, times and date-times become
// the text the file holds, because JSON has no date.
//

const std = @import("std");
const toml = @import("toml");
const utils = @import("utils");
const errors = utils.errors;

//
// Converts a parsed TOML table to the JSON object the package works in. `text` is the source the table was parsed from, which the spans
// address, so a date, a time or a date-time becomes a string holding its own text.
//
pub fn tomlToJson(
    arena: std.mem.Allocator,
    text: []const u8,
    table: toml.Value,
    spans: *const toml.Spans,
) !std.json.ObjectMap {
    std.debug.assert(table == .table);
    const converted = try valueToJson(arena, text, table, spans, "");
    return converted.object;
}

//
// Converts one TOML value at a path, naming its children with the path the library records spans under.
//
fn valueToJson(
    arena: std.mem.Allocator,
    text: []const u8,
    value: toml.Value,
    spans: *const toml.Spans,
    path: []const u8,
) !std.json.Value {
    switch (value) {
        .string => |text_value| return .{ .string = try arena.dupe(u8, text_value) },
        .integer => |number| return .{ .integer = number },
        .float => |number| return .{ .float = number },
        .boolean => |boolean| return .{ .bool = boolean },
        .datetime, .date, .time => {
            const span = spans.get(path) orelse return errors.throwError("The TOML value at \"{s}\" has no recorded span.", .{path});
            return .{ .string = try arena.dupe(u8, text[@intCast(span.start)..@intCast(span.end)]) };
        },
        .array => |array| {
            var converted: std.json.Array = .init(arena);
            for (array.items, 0..) |item, index| {
                const item_path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ path, index });
                try converted.append(try valueToJson(arena, text, item, spans, item_path));
            }
            return .{ .array = converted };
        },
        .table => |table| {
            var converted: std.json.ObjectMap = .empty;
            var iterator = table.iterator();
            while (iterator.next()) |entry| {
                const key_path = if (path.len == 0)
                    try arena.dupe(u8, entry.key_ptr.*)
                else
                    try std.mem.concat(arena, u8, &.{ path, ".", entry.key_ptr.* });
                try converted.put(arena, try arena.dupe(u8, entry.key_ptr.*), try valueToJson(arena, text, entry.value_ptr.*, spans, key_path));
            }
            return .{ .object = converted };
        },
    }
}

//
// Converts a JSON object to a TOML table. A null member is left out, since TOML has no null. A number string, a null inside a list or a list
// that mixes tables with other values cannot be TOML, and fails naming the key.
//
pub fn jsonToToml(arena: std.mem.Allocator, object: std.json.ObjectMap) !toml.Value {
    var table: toml.Value = .makeTable();
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* == .null) {
            continue;
        }
        try table.tablePut(arena, entry.key_ptr.*, try jsonValueToToml(arena, entry.value_ptr.*, entry.key_ptr.*));
    }
    return table;
}

//
// Converts one JSON value to a TOML value, failing with `error.ConfigValueNotToml` for a value TOML cannot hold.
//
pub fn jsonValueToToml(arena: std.mem.Allocator, value: std.json.Value, key_path: []const u8) !toml.Value {
    return switch (value) {
        .null => error.ConfigValueNotToml,
        .bool => |boolean| .{ .boolean = boolean },
        .integer => |number| .{ .integer = number },
        .float => |number| .{ .float = number },
        .number_string => notToml("The setting \"{s}\" is a number too wide for a file to hold.", .{key_path}),
        .string => |text| .{ .string = try arena.dupe(u8, text) },
        .array => |array| blk: {
            var converted: toml.Value = .makeArray();
            var table_count: usize = 0;
            var other_count: usize = 0;
            for (array.items, 0..) |item, index| {
                if (item == .null) {
                    return notToml("The setting \"{s}\" holds a null in a list, which a file cannot hold.", .{key_path});
                }
                const item_path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ key_path, index });
                try converted.arrayAppend(arena, try jsonValueToToml(arena, item, item_path));
                if (item == .object) {
                    table_count += 1;
                }
                else {
                    other_count += 1;
                }
            }
            if (table_count > 0 and other_count > 0) {
                return notToml("The setting \"{s}\" mixes tables and other values in one list, which a file cannot hold.", .{key_path});
            }
            break :blk converted;
        },
        .object => |object| blk: {
            var table: toml.Value = .makeTable();
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* == .null) {
                    continue;
                }
                const child_path = try std.mem.concat(arena, u8, &.{ key_path, ".", entry.key_ptr.* });
                try table.tablePut(arena, entry.key_ptr.*, try jsonValueToToml(arena, entry.value_ptr.*, child_path));
            }
            break :blk table;
        },
    };
}

//
// A deep equality of two JSON values, with objects compared by key whatever their order.
//
pub fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
        return false;
    }
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .string => std.mem.eql(u8, a.string, b.string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) {
                break :blk false;
            }
            for (a.array.items, b.array.items) |a_item, b_item| {
                if (!jsonEqual(a_item, b_item)) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) {
                break :blk false;
            }
            var iterator = a.object.iterator();
            while (iterator.next()) |entry| {
                const b_value = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(entry.value_ptr.*, b_value)) {
                    break :blk false;
                }
            }
            break :blk true;
        },
    };
}

//
// Records the message of a value TOML cannot hold and fails with `error.ConfigValueNotToml`.
//
fn notToml(comptime format: []const u8, args: anytype) error{ConfigValueNotToml} {
    errors.recordError("Error", format, args);
    return error.ConfigValueNotToml;
}
