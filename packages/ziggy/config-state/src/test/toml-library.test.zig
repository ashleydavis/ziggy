//
// The behaviour of the TOML library that the config file code is built on.
//

const std = @import("std");
const toml = @import("toml");

test "toml library: parse records every kind and the spans of dates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\title = "demo"
        \\count = 42
        \\ratio = 1.5
        \\enabled = true
        \\when = 2026-01-02
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
        \\[[items]]
        \\when = 2026-01-03
        \\name = "first"
        \\
        \\[[items]]
        \\when = 2026-01-04
        \\name = "second"
    ;
    var spans: toml.Spans = .empty;
    const value = try toml.parse(arena, source, .{ .spans = &spans });

    try std.testing.expect(value == .table);
    try std.testing.expectEqualStrings("demo", value.tableGet("title").?.string);
    try std.testing.expectEqual(@as(i64, 42), value.tableGet("count").?.integer);
    try std.testing.expectEqual(@as(f64, 1.5), value.tableGet("ratio").?.float);
    try std.testing.expect(value.tableGet("enabled").?.boolean);
    try std.testing.expect(value.tableGet("when").? == .date);

    const server = value.tableGet("server").?;
    try std.testing.expect(server == .table);
    try std.testing.expectEqualStrings("localhost", server.tableGet("host").?.string);
    try std.testing.expectEqual(@as(i64, 8080), server.tableGet("port").?.integer);

    const items = value.tableGet("items").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("first", items[0].tableGet("name").?.string);
    try std.testing.expectEqualStrings("second", items[1].tableGet("name").?.string);

    const when_span = spans.get("when").?;
    try std.testing.expectEqualStrings("2026-01-02", source[@intCast(when_span.start)..@intCast(when_span.end)]);
    const item_span = spans.get("items[0].when").?;
    try std.testing.expectEqualStrings("2026-01-03", source[@intCast(item_span.start)..@intCast(item_span.end)]);
}

test "toml library: a bad line is a parse error with a diagnostic on its line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\a = 1
        \\oops = = 1
    ;
    var diagnostics: std.ArrayList(toml.Diagnostic) = .empty;
    try std.testing.expectError(error.TomlParseError, toml.parse(arena, source, .{ .errors = &diagnostics }));

    try std.testing.expect(diagnostics.items.len > 0);
    try std.testing.expect(diagnostics.items[0].message.len > 0);
    try std.testing.expectEqual(@as(u32, 2), diagnostics.items[0].span.lineCol(source).line);
}

test "toml library: encode writes sub-tables and arrays of tables that parse back equal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var root: toml.Value = .makeTable();
    try root.tablePut(arena, "name", try toml.Value.fromString(arena, "demo"));
    try root.tablePut(arena, "count", .{ .integer = 3 });
    try root.tablePut(arena, "ratio", .{ .float = 0.5 });
    try root.tablePut(arena, "enabled", .{ .boolean = true });

    var tags: toml.Value = .makeArray();
    try tags.arrayAppend(arena, try toml.Value.fromString(arena, "alpha"));
    try tags.arrayAppend(arena, try toml.Value.fromString(arena, "beta"));
    try root.tablePut(arena, "tags", tags);

    const empty: toml.Value = .makeTable();
    try root.tablePut(arena, "empty", empty);

    var sub: toml.Value = .makeTable();
    try sub.tablePut(arena, "port", .{ .integer = 8080 });
    try root.tablePut(arena, "sub", sub);

    var list: toml.Value = .makeArray();
    var first: toml.Value = .makeTable();
    try first.tablePut(arena, "id", .{ .integer = 1 });
    var second: toml.Value = .makeTable();
    try second.tablePut(arena, "id", .{ .integer = 2 });
    try list.arrayAppend(arena, first);
    try list.arrayAppend(arena, second);
    try root.tablePut(arena, "list", list);

    var allocating: std.Io.Writer.Allocating = .init(arena);
    defer allocating.deinit();
    try toml.encode(&allocating.writer, root, .{ .sort_keys = true });
    const text = allocating.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "[sub]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[[list]]") != null);
    const parsed = try toml.parse(arena, text, .{});
    try std.testing.expect(toml.Value.eql(root, parsed));

    const empty_root: toml.Value = .makeTable();
    var empty_allocating: std.Io.Writer.Allocating = .init(arena);
    defer empty_allocating.deinit();
    try toml.encode(&empty_allocating.writer, empty_root, .{});
    const empty_parsed = try toml.parse(arena, empty_allocating.written(), .{});
    try std.testing.expectEqual(@as(usize, 0), empty_parsed.table.count());
}

test "toml library: a document edit keeps comments and other keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\# the top comment
        \\a = 1 # trailing
        \\b = 2
        \\
        \\[sync]
        \\# the sync comment
        \\k = 1
    ;
    var document = try toml.Document.parse(arena, source, .{});
    try document.setValue("a", .{ .integer = 5 });
    try document.setValueSegments(&.{ "sync", "j" }, .{ .boolean = true });
    try document.remove("b");

    var allocating: std.Io.Writer.Allocating = .init(arena);
    defer allocating.deinit();
    try document.emit(&allocating.writer);
    const text = allocating.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "# the top comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "a = 5 # trailing") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# the sync comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "k = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "b = 2") == null);

    const parsed = try toml.parse(arena, text, .{});
    try std.testing.expectEqual(@as(i64, 5), parsed.get("a").?.integer);
    try std.testing.expect(parsed.get("sync.j").?.boolean);
}

test "toml library: an empty document takes a first value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var document = try toml.Document.empty(arena, .{});
    try document.setValue("a", .{ .string = "x" });

    var allocating: std.Io.Writer.Allocating = .init(arena);
    defer allocating.deinit();
    try document.emit(&allocating.writer);
    const parsed = try toml.parse(arena, allocating.written(), .{});
    try std.testing.expectEqualStrings("x", parsed.get("a").?.string);
}
