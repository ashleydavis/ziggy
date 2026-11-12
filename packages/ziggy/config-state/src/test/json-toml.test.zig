//
// The conversion between the TOML library's values and the package's JSON values, and the deep equality the edits are checked with.
//

const std = @import("std");
const toml = @import("toml");
const json_toml = @import("config_state").json_toml;
const utils = @import("utils");

test "json toml: every TOML kind converts to JSON and back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\text = "hello"
        \\count = 42
        \\ratio = 1.5
        \\flag = true
        \\list = ["a", "b"]
        \\[table]
        \\inner = 2
        \\[[items]]
        \\name = "first"
        \\[[items]]
        \\name = "second"
    ;
    var spans: toml.Spans = .empty;
    const parsed = try toml.parse(arena, source, .{ .spans = &spans });
    const values = try json_toml.tomlToJson(arena, source, parsed, &spans);

    try std.testing.expectEqualStrings("hello", values.get("text").?.string);
    try std.testing.expectEqual(@as(i64, 42), values.get("count").?.integer);
    try std.testing.expectEqual(@as(f64, 1.5), values.get("ratio").?.float);
    try std.testing.expect(values.get("flag").?.bool);
    try std.testing.expectEqual(@as(usize, 2), values.get("list").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 2), values.get("table").?.object.get("inner").?.integer);
    try std.testing.expectEqualStrings("second", values.get("items").?.array.items[1].object.get("name").?.string);

    const back = try json_toml.jsonToToml(arena, values);
    const reparsed = try toml.parse(arena, try textOf(arena, back), .{});
    try std.testing.expect(toml.Value.eql(parsed, reparsed));
}

test "json toml: dates and times become the text the file holds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\date = 2026-01-02
        \\time = 07:32:00
        \\stamp = 2026-01-02T07:32:00Z
        \\[table]
        \\date = 2026-01-03
        \\[[items]]
        \\date = 2026-01-04
    ;
    var spans: toml.Spans = .empty;
    const parsed = try toml.parse(arena, source, .{ .spans = &spans });
    const values = try json_toml.tomlToJson(arena, source, parsed, &spans);

    try std.testing.expectEqualStrings("2026-01-02", values.get("date").?.string);
    try std.testing.expectEqualStrings("07:32:00", values.get("time").?.string);
    try std.testing.expectEqualStrings("2026-01-02T07:32:00Z", values.get("stamp").?.string);
    try std.testing.expectEqualStrings("2026-01-03", values.get("table").?.object.get("date").?.string);
    try std.testing.expectEqualStrings("2026-01-04", values.get("items").?.array.items[0].object.get("date").?.string);
}

test "json toml: a null member is left out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "kept", .{ .integer = 1 });
    try object.put(arena, "removed", .null);
    const table = try json_toml.jsonToToml(arena, object);
    try std.testing.expect(table.tableGet("kept") != null);
    try std.testing.expect(table.tableGet("removed") == null);
}

test "json toml: a null in a list, a number string and a mixed list fail naming the key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var with_null: std.json.ObjectMap = .empty;
    var null_list: std.json.Array = .init(arena);
    try null_list.append(.null);
    try with_null.put(arena, "values", .{ .array = null_list });
    try std.testing.expectError(error.ConfigValueNotToml, json_toml.jsonToToml(arena, with_null));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "values") != null);

    var with_number_string: std.json.ObjectMap = .empty;
    try with_number_string.put(arena, "big", .{ .number_string = "123" });
    try std.testing.expectError(error.ConfigValueNotToml, json_toml.jsonToToml(arena, with_number_string));

    var with_mixed: std.json.ObjectMap = .empty;
    var mixed: std.json.Array = .init(arena);
    var table: std.json.ObjectMap = .empty;
    try table.put(arena, "a", .{ .integer = 1 });
    try mixed.append(.{ .object = table });
    try mixed.append(.{ .integer = 2 });
    try with_mixed.put(arena, "items", .{ .array = mixed });
    try std.testing.expectError(error.ConfigValueNotToml, json_toml.jsonToToml(arena, with_mixed));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "items") != null);
}

test "json toml: equality ignores key order and tells kinds, lengths and nested values apart" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var first: std.json.ObjectMap = .empty;
    try first.put(arena, "a", .{ .integer = 1 });
    try first.put(arena, "b", .{ .string = "x" });
    var second: std.json.ObjectMap = .empty;
    try second.put(arena, "b", .{ .string = "x" });
    try second.put(arena, "a", .{ .integer = 1 });
    try std.testing.expect(json_toml.jsonEqual(.{ .object = first }, .{ .object = second }));

    try std.testing.expect(!json_toml.jsonEqual(.{ .integer = 1 }, .{ .float = 1 }));
    try std.testing.expect(!json_toml.jsonEqual(.{ .string = "a" }, .{ .string = "b" }));

    var shorter: std.json.Array = .init(arena);
    try shorter.append(.{ .integer = 1 });
    var longer: std.json.Array = .init(arena);
    try longer.append(.{ .integer = 1 });
    try longer.append(.{ .integer = 2 });
    try std.testing.expect(!json_toml.jsonEqual(.{ .array = shorter }, .{ .array = longer }));

    var nested_a: std.json.ObjectMap = .empty;
    try nested_a.put(arena, "inner", .{ .integer = 1 });
    var nested_b: std.json.ObjectMap = .empty;
    try nested_b.put(arena, "inner", .{ .integer = 2 });
    try std.testing.expect(!json_toml.jsonEqual(.{ .object = nested_a }, .{ .object = nested_b }));
}

//
// The text a TOML value writes.
//
fn textOf(arena: std.mem.Allocator, value: toml.Value) ![]const u8 {
    var allocating: std.Io.Writer.Allocating = .init(arena);
    defer allocating.deinit();
    try toml.encode(&allocating.writer, value, .{});
    return arena.dupe(u8, allocating.written());
}
