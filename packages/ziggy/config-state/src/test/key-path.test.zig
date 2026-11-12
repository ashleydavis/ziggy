//
// Dotted key paths: splitting one, reading the value at one and writing one while keeping every other key.
//

const std = @import("std");
const key_path = @import("config_state").key_path;
const typed = @import("config_state").typed;
const utils = @import("utils");

test "key path: splits one key and three" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const one = try key_path.split(arena, "sidebar");
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("sidebar", one[0]);

    const three = try key_path.split(arena, "sidebar.left.open");
    try std.testing.expectEqual(@as(usize, 3), three.len);
    try std.testing.expectEqualStrings("sidebar", three[0]);
    try std.testing.expectEqualStrings("left", three[1]);
    try std.testing.expectEqualStrings("open", three[2]);
}

test "key path: an empty path and each empty key fail naming the path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Thrown, key_path.split(arena, ""));
    for ([_][]const u8{ "a..b", ".a", "a." }) |path| {
        try std.testing.expectError(error.Thrown, key_path.split(arena, path));
        try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), path) != null);
    }
}

test "key path: lookup finds a value three tables deep and misses an absent key at each depth" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const values = try nestedValues(arena);
    const keys = try key_path.split(arena, "a.b.c");
    const found = try key_path.lookup(values, .config, keys);
    try std.testing.expectEqual(@as(i64, 1), found.?.integer);

    try std.testing.expect(try key_path.lookup(values, .config, try key_path.split(arena, "missing")) == null);
    try std.testing.expect(try key_path.lookup(values, .config, try key_path.split(arena, "a.missing")) == null);
    try std.testing.expect(try key_path.lookup(values, .config, try key_path.split(arena, "a.b.missing")) == null);
}

test "key path: lookup through a value that is not a table fails naming the key path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const values = try nestedValues(arena);
    try std.testing.expectError(error.Thrown, key_path.lookup(values, .config, try key_path.split(arena, "a.b.c.d")));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "a.b.c") != null);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "a table") != null);
}

test "key path: put sets three tables deep, replaces, removes, and keeps every other key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const values = try nestedValues(arena);
    const keys = try key_path.split(arena, "a.b.c");

    const changed = try key_path.put(arena, values, .config, keys, .{ .integer = 5 });
    try std.testing.expectEqual(@as(i64, 5), (try key_path.lookup(changed, .config, keys)).?.integer);
    try std.testing.expectEqual(@as(i64, 2), (try key_path.lookup(changed, .config, try key_path.split(arena, "a.b.other"))).?.integer);
    try std.testing.expectEqualStrings("x", (try key_path.lookup(changed, .config, try key_path.split(arena, "top"))).?.string);

    // The values it was given are untouched.
    try std.testing.expectEqual(@as(i64, 1), (try key_path.lookup(values, .config, keys)).?.integer);

    const created = try key_path.put(arena, values, .config, try key_path.split(arena, "new.deeper.key"), .{ .bool = true });
    try std.testing.expect((try key_path.lookup(created, .config, try key_path.split(arena, "new.deeper.key"))).?.bool);
    try std.testing.expectEqual(@as(i64, 2), (try key_path.lookup(created, .config, try key_path.split(arena, "a.b.other"))).?.integer);

    const removed = try key_path.put(arena, changed, .config, keys, null);
    try std.testing.expect(try key_path.lookup(removed, .config, keys) == null);
    try std.testing.expectEqual(@as(i64, 2), (try key_path.lookup(removed, .config, try key_path.split(arena, "a.b.other"))).?.integer);
}

test "key path: put through a value that is not a table fails naming the key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const values = try nestedValues(arena);
    try std.testing.expectError(error.Thrown, key_path.put(arena, values, .config, try key_path.split(arena, "top.deeper"), .{ .integer = 1 }));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "top") != null);
}

//
// The values every test starts from: a value three tables deep, another key beside it, and a top-level string.
//
fn nestedValues(arena: std.mem.Allocator) !std.json.ObjectMap {
    var inner: std.json.ObjectMap = .empty;
    try inner.put(arena, "c", .{ .integer = 1 });
    try inner.put(arena, "other", .{ .integer = 2 });
    var middle: std.json.ObjectMap = .empty;
    try middle.put(arena, "b", .{ .object = inner });
    var outer: std.json.ObjectMap = .empty;
    try outer.put(arena, "a", .{ .object = middle });
    try outer.put(arena, "top", .{ .string = "x" });
    return outer;
}
