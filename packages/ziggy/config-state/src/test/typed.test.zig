//
// The typed conversion between a file's values and the app's Zig types: every kind it takes, and every failure it names.
//

const std = @import("std");
const typed = @import("config_state").typed;
const utils = @import("utils");

const Colour = enum { red, green };

const Inner = struct {
    open: bool,
    count: u8 = 3,
};

const Outer = struct {
    inner: Inner,
};

const Item = struct {
    name: []const u8,
};

const WithDefault = struct {
    name: []const u8 = "none",
    flag: ?bool,
};

const WithItems = struct {
    items: []const Item,
};

test "typed: booleans and strings round trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const encoded_bool = (try typed.encode(arena, .config, "flag", true)).?;
    try std.testing.expectEqual(true, encoded_bool.bool);
    try std.testing.expect(try typed.decode(bool, arena, .config, "flag", encoded_bool));

    const encoded_text = (try typed.encode(arena, .config, "name", "blue")).?;
    try std.testing.expectEqualStrings("blue", encoded_text.string);
    try std.testing.expectEqualStrings("blue", try typed.decode([]const u8, arena, .config, "name", encoded_text));
    try std.testing.expectEqualStrings("blue", try typed.decode([]u8, arena, .config, "name", encoded_text));
}

test "typed: every integer width round trips and an integer out of range is named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = .{
        .{ .value = @as(u8, 200), .setting_type = u8 },
        .{ .value = @as(i32, -12), .setting_type = i32 },
        .{ .value = @as(u64, 300), .setting_type = u64 },
        .{ .value = @as(i64, -300), .setting_type = i64 },
    };
    inline for (cases) |case| {
        const encoded = (try typed.encode(arena, .config, "count", case.value)).?;
        try std.testing.expectEqual(@as(i64, case.value), encoded.integer);
        try std.testing.expectEqual(case.value, try typed.decode(case.setting_type, arena, .config, "count", encoded));
    }

    const too_big: std.json.Value = .{ .integer = 300 };
    try std.testing.expectError(error.SettingWrongType, typed.decode(u8, arena, .config, "count", too_big));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "300") != null);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "u8") != null);

    try std.testing.expectError(error.Thrown, typed.encode(arena, .config, "count", @as(u64, @intCast(std.math.maxInt(i64) + 1))));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "i64") != null);
}

test "typed: floats take a float or an integer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const from_float: std.json.Value = .{ .float = 1.5 };
    try std.testing.expectEqual(@as(f64, 1.5), try typed.decode(f64, arena, .config, "ratio", from_float));
    try std.testing.expectEqual(@as(f32, 1.5), try typed.decode(f32, arena, .config, "ratio", from_float));

    const from_integer: std.json.Value = .{ .integer = 3 };
    try std.testing.expectEqual(@as(f64, 3), try typed.decode(f64, arena, .config, "ratio", from_integer));

    const encoded = (try typed.encode(arena, .config, "ratio", @as(f32, 2.5))).?;
    try std.testing.expectEqual(@as(f64, 2.5), encoded.float);
}

test "typed: literals are accepted by encode only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(i64, 7), (try typed.encode(arena, .config, "count", 7)).?.integer);
    try std.testing.expectEqual(@as(f64, 0.25), (try typed.encode(arena, .config, "ratio", 0.25)).?.float);
    try std.testing.expectEqualStrings("literal", (try typed.encode(arena, .config, "name", "literal")).?.string);
}

test "typed: enums take their tag name and name a string that matches none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const encoded = (try typed.encode(arena, .config, "colour", Colour.green)).?;
    try std.testing.expectEqualStrings("green", encoded.string);
    try std.testing.expectEqual(Colour.green, try typed.decode(Colour, arena, .config, "colour", encoded));

    try std.testing.expectError(error.SettingWrongType, typed.decode(Colour, arena, .config, "colour", .{ .string = "purple" }));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "purple") != null);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "Colour") != null);
}

test "typed: optionals take a present value, an absent one and a JSON null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(?i64, 4), try typed.decode(?i64, arena, .config, "count", .{ .integer = 4 }));
    try std.testing.expectEqual(@as(?i64, null), try typed.decode(?i64, arena, .config, "count", null));
    try std.testing.expectEqual(@as(?i64, null), try typed.decode(?i64, arena, .config, "count", .null));
    try std.testing.expect((try typed.encode(arena, .config, "count", @as(?i64, null))) == null);
}

test "typed: lists and slices of integers, strings and structs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const numbers = [_]i64{ 1, 2, 3 };
    const encoded_numbers = (try typed.encode(arena, .config, "numbers", numbers)).?;
    const decoded_numbers = try typed.decode([]const i64, arena, .config, "numbers", encoded_numbers);
    try std.testing.expectEqual(@as(usize, 3), decoded_numbers.len);
    try std.testing.expectEqual(@as(i64, 2), decoded_numbers[1]);

    const strings = [_][]const u8{ "alpha", "beta" };
    const encoded_strings = (try typed.encode(arena, .config, "tags", strings)).?;
    const decoded_strings = try typed.decode([]const []const u8, arena, .config, "tags", encoded_strings);
    try std.testing.expectEqualStrings("beta", decoded_strings[1]);

    const items = [_]Item{ .{ .name = "one" }, .{ .name = "two" } };
    const encoded_items = (try typed.encode(arena, .config, "items", items)).?;
    const decoded_items = try typed.decode([]const Item, arena, .config, "items", encoded_items);
    try std.testing.expectEqualStrings("two", decoded_items[1].name);
}

test "typed: a fixed array needs its own length and names both" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = [3]u8{ 1, 2, 3 };
    const encoded = (try typed.encode(arena, .config, "bytes", bytes)).?;
    const decoded = try typed.decode([3]u8, arena, .config, "bytes", encoded);
    try std.testing.expectEqual(@as(u8, 3), decoded[2]);

    const shorter: std.json.Value = .{ .array = try arrayOf(arena, &.{ .{ .integer = 1 }, .{ .integer = 2 } }) };
    try std.testing.expectError(error.SettingWrongType, typed.decode([3]u8, arena, .config, "bytes", shorter));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "3") != null);
}

test "typed: a struct reads its fields, defaults, optionals and a table key it does not name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var inner: std.json.ObjectMap = .empty;
    try inner.put(arena, "open", .{ .bool = true });
    try inner.put(arena, "ignored", .{ .integer = 9 });
    var outer: std.json.ObjectMap = .empty;
    try outer.put(arena, "inner", .{ .object = inner });

    const decoded = try typed.decode(Outer, arena, .config, "outer", .{ .object = outer });
    try std.testing.expect(decoded.inner.open);
    try std.testing.expectEqual(@as(u8, 3), decoded.inner.count);

    var with_default: std.json.ObjectMap = .empty;
    try with_default.put(arena, "flag", .null);
    const decoded_default = try typed.decode(WithDefault, arena, .config, "setting", .{ .object = with_default });
    try std.testing.expectEqualStrings("none", decoded_default.name);
    try std.testing.expect(decoded_default.flag == null);

    const missing_required: std.json.ObjectMap = .empty;
    try std.testing.expectError(error.Thrown, typed.decode(Outer, arena, .config, "outer", .{ .object = missing_required }));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "outer.inner") != null);
}

test "typed: a struct nested three deep, with a slice of structs, round trips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Deep = struct {
        level: struct {
            middle: struct {
                items: []const Item,
            },
        },
    };
    const value: Deep = .{ .level = .{ .middle = .{ .items = &.{.{ .name = "a" }} } } };
    const encoded = (try typed.encode(arena, .config, "deep", value)).?;
    const decoded = try typed.decode(Deep, arena, .config, "deep", encoded);
    try std.testing.expectEqualStrings("a", decoded.level.middle.items[0].name);
}

test "typed: encode leaves out a field whose value is null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const value: WithDefault = .{ .name = "set", .flag = null };
    const encoded = (try typed.encode(arena, .config, "setting", value)).?;
    try std.testing.expect(encoded.object.get("flag") == null);
    try std.testing.expectEqualStrings("set", encoded.object.get("name").?.string);
}

test "typed: an absent value of a type that is not optional fails naming the key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Thrown, typed.decode(bool, arena, .config, "flag", null));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "\"flag\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "cannot be absent") != null);
}

test "typed: every wrong kind fails with SettingWrongType naming the key, the type and the kind found" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = .{
        .{ .setting_type = bool, .value = std.json.Value{ .string = "yes" } },
        .{ .setting_type = []const u8, .value = std.json.Value{ .integer = 1 } },
        .{ .setting_type = Inner, .value = std.json.Value{ .array = try arrayOf(arena, &.{.{ .integer = 1 }}) } },
        .{ .setting_type = i64, .value = std.json.Value{ .object = try objectOf(arena) } },
        .{ .setting_type = i32, .value = std.json.Value{ .float = 1.5 } },
    };
    inline for (cases) |case| {
        try std.testing.expectError(error.SettingWrongType, typed.decode(case.setting_type, arena, .config, "setting", case.value));
        try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "setting") != null);
        try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "config") != null);
    }
}

test "typed: a float that is not finite cannot be written to the state file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Thrown, typed.encode(arena, .state, "ratio", std.math.nan(f64)));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "ratio") != null);

    // The config file can hold it, as TOML has floats for NaN and infinity, but a change never writes it back.
    _ = try typed.encode(arena, .config, "ratio", std.math.nan(f64));
}

//
// An array of the given values.
//
fn arrayOf(arena: std.mem.Allocator, values: []const std.json.Value) !std.json.Array {
    var array: std.json.Array = .init(arena);
    for (values) |value| {
        try array.append(value);
    }
    return array;
}

//
// An empty object.
//
fn objectOf(arena: std.mem.Allocator) !std.json.ObjectMap {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "unused", .{ .integer = 0 });
    return object;
}
