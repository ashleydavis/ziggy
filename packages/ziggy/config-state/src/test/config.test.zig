//
// The config file: parsing it, reading and writing keys, keeping its comments, and the atomic updates that make writers take turns.
//

const std = @import("std");
const toml = @import("toml");
const config = @import("config_state").config;
const utils = @import("utils");

test "config: parses a good file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const read_result = try config.parse(arena, .{ .path = "config.toml", .text = "name = \"blue\"\n" });
    try std.testing.expect(read_result.problem == null);
    try std.testing.expectEqualStrings("blue", read_result.values.get("name").?.string);
    try std.testing.expectEqualStrings("name = \"blue\"\n", read_result.text);
}

test "config: a bad line gives the line, the column and the reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const read_result = try config.parse(arena, .{ .path = "config.toml", .text = "a = 1\noops = = 1\n" });
    try std.testing.expectEqual(@as(usize, 0), read_result.values.count());
    try std.testing.expect(read_result.problem != null);
    try std.testing.expectEqual(@as(u32, 2), read_result.problem.?.line);
    try std.testing.expect(read_result.problem.?.column > 0);
    try std.testing.expect(read_result.problem.?.reason.len > 0);
}

test "config: read of a missing file is empty, and of a file over the limit is a problem on line 1" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const missing = try config.read(arena, std.testing.io, path);
    try std.testing.expectEqual(@as(usize, 0), missing.values.count());
    try std.testing.expect(missing.problem == null);
    try std.testing.expectEqualStrings("", missing.text);

    const big = try arena.alloc(u8, config.read_limit_bytes + 1);
    @memset(big, 'a');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.toml", .data = big });
    const too_big = try config.read(arena, std.testing.io, path);
    try std.testing.expectEqual(@as(usize, 0), too_big.values.count());
    try std.testing.expectEqual(@as(u32, 1), too_big.problem.?.line);
    try std.testing.expect(std.mem.indexOf(u8, too_big.problem.?.reason, "larger than 1 MiB") != null);

    try std.testing.expect((try config.problem(arena, std.testing.io, path)) != null);
}

test "config: every type round trips through the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    const Colour = enum { red, green };
    const Settings = struct {
        left: struct {
            open: bool,
            width: u8,
        },
    };
    const Item = struct { name: []const u8 };

    try config.set(arena, io, path, "flag", true);
    try config.set(arena, io, path, "count", @as(i64, -3));
    try config.set(arena, io, path, "ratio", @as(f64, 1.5));
    try config.set(arena, io, path, "name", "blue");
    try config.set(arena, io, path, "colour", Colour.green);
    try config.set(arena, io, path, "optional", @as(?i64, null));
    try config.set(arena, io, path, "sidebar", Settings{ .left = .{ .open = true, .width = 20 } });
    try config.set(arena, io, path, "items", &[_]Item{ .{ .name = "one" }, .{ .name = "two" } });

    try std.testing.expect(try config.get(bool, arena, io, path, "flag"));
    try std.testing.expectEqual(@as(i64, -3), try config.get(i64, arena, io, path, "count"));
    try std.testing.expectEqual(@as(f64, 1.5), try config.get(f64, arena, io, path, "ratio"));
    try std.testing.expectEqualStrings("blue", try config.get([]const u8, arena, io, path, "name"));
    try std.testing.expectEqual(Colour.green, try config.get(Colour, arena, io, path, "colour"));
    try std.testing.expectEqual(@as(?i64, null), try config.get(?i64, arena, io, path, "optional"));
    const whole = try config.get(Settings, arena, io, path, "sidebar");
    try std.testing.expect(whole.left.open);
    try std.testing.expectEqual(@as(u8, 20), whole.left.width);
    try std.testing.expect(try config.get(bool, arena, io, path, "sidebar.left.open"));
    const items = try config.get([]const Item, arena, io, path, "items");
    try std.testing.expectEqualStrings("two", items[1].name);

    const text = try fileText(arena, path);
    try std.testing.expect(std.mem.indexOf(u8, text, "[[items]]") != null);
    const parsed = try toml.parse(arena, text, .{});
    try std.testing.expectEqual(@as(i64, 20), parsed.get("sidebar.left.width").?.integer);
}

test "config: an absent key is null for an optional type and an error otherwise" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(?i64, null), try config.get(?i64, arena, std.testing.io, path, "missing"));
    try std.testing.expectError(error.Thrown, config.get(i64, arena, std.testing.io, path, "missing"));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "missing") != null);
}

test "config: a value of the wrong type is named, and a date reads as its text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);
    try writeFile(path, "count = \"text\"\nwhen = 2026-01-02\n");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.SettingWrongType, config.get(i64, arena, std.testing.io, path, "count"));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "count") != null);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "a string") != null);
    try std.testing.expectEqualStrings("2026-01-02", try config.get([]const u8, arena, std.testing.io, path, "when"));
}

test "config: a file with a bad line gives every key as absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);
    try writeFile(path, "a = 1\noops = = 1\n");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqual(@as(?i64, null), try config.get(?i64, arena_state.allocator(), std.testing.io, path, "a"));
}

test "config: set adds, replaces and removes a key and keeps every other key and comment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);
    try writeFile(path,
        \\# the top comment
        \\a = 1 # trailing
        \\b = 2
        \\
        \\[sync]
        \\# the sync comment
        \\k = 1
    );

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    try config.set(arena, io, path, "a", @as(i64, 5));
    try config.set(arena, io, path, "sync.j", true);
    try config.set(arena, io, path, "b", @as(?i64, null));
    try config.set(arena, io, path, "new.deep.key", @as(i64, 7));

    const text = try fileText(arena, path);
    try std.testing.expect(std.mem.indexOf(u8, text, "# the top comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "a = 5 # trailing") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# the sync comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "b = 2") == null);
    try std.testing.expectEqual(@as(i64, 5), try config.get(i64, arena, io, path, "a"));
    try std.testing.expect(try config.get(bool, arena, io, path, "sync.j"));
    try std.testing.expectEqual(@as(i64, 7), try config.get(i64, arena, io, path, "new.deep.key"));
    try std.testing.expectEqual(@as(i64, 1), try config.get(i64, arena, io, path, "sync.k"));
}

test "config: a struct over an existing table keeps the comments outside it, and a date it does not change stays a date" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);
    try writeFile(path,
        \\# above
        \\when = 2026-01-02
        \\[sync]
        \\# inside
        \\enabled = false
    );

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Sync = struct { enabled: bool, extra: u8 };

    try config.set(arena, std.testing.io, path, "sync", Sync{ .enabled = true, .extra = 3 });
    const text = try fileText(arena, path);
    try std.testing.expect(std.mem.indexOf(u8, text, "# above") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2026-01-02") != null);
    try std.testing.expect(try config.get(bool, arena, std.testing.io, path, "sync.enabled"));
    try std.testing.expectEqual(@as(i64, 3), try config.get(i64, arena, std.testing.io, path, "sync.extra"));
}

test "config: a changed array of tables writes a file that parses to the new values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Item = struct { name: []const u8 };

    try config.set(arena, std.testing.io, path, "items", &[_]Item{ .{ .name = "one" }, .{ .name = "two" } });
    try config.set(arena, std.testing.io, path, "items", &[_]Item{.{ .name = "three" }});
    const items = try config.get([]const Item, arena, std.testing.io, path, "items");
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("three", items[0].name);
}

test "config: set creates a missing file, and through a key that is not a table it fails and changes nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try config.set(arena, std.testing.io, path, "created", true);
    try std.testing.expect(try config.get(bool, arena, std.testing.io, path, "created"));

    try writeFile(path, "x = 1\n");
    try std.testing.expectError(error.Thrown, config.set(arena, std.testing.io, path, "x.y", @as(i64, 2)));
    try std.testing.expectEqualStrings("x = 1\n", try fileText(arena, path));
}

test "config: get does not create the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqual(@as(?i64, null), try config.get(?i64, arena_state.allocator(), std.testing.io, path, "missing"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, path, .{}));
}

test "config: set on a file with a bad line fails and leaves the bytes alone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);
    const bad = "a = 1\noops = = 1\n";
    try writeFile(path, bad);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.ConfigFileInvalid, config.set(arena, std.testing.io, path, "a", @as(i64, 2)));
    try std.testing.expectEqualStrings(bad, try fileText(arena, path));
}

test "config: two set calls on different keys both survive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try config.set(arena, std.testing.io, path, "first", @as(i64, 1));
    try config.set(arena, std.testing.io, path, "second", @as(i64, 2));
    try std.testing.expectEqual(@as(i64, 1), try config.get(i64, arena, std.testing.io, path, "first"));
    try std.testing.expectEqual(@as(i64, 2), try config.get(i64, arena, std.testing.io, path, "second"));
}

test "config: edit on empty text writes the new values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var new_values: std.json.ObjectMap = .empty;
    try new_values.put(arena, "a", .{ .integer = 1 });
    const text = try config.edit(arena, .{ .text = "", .old_values = .empty, .new_values = new_values });
    const parsed = try toml.parse(arena, text, .{});
    try std.testing.expectEqual(@as(i64, 1), parsed.get("a").?.integer);
}

test "config: update reads a list and writes it back in one change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try config.set(arena, std.testing.io, path, "shared.untouched", @as(i64, 9));
    try config.update(arena, std.testing.io, path, ListAppend{ .item = "one" });
    try config.update(arena, std.testing.io, path, ListAppend{ .item = "two" });
    const list = (try config.get(?[]const []const u8, arena, std.testing.io, path, "shared.items")).?;
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("one", list[0]);
    try std.testing.expectEqualStrings("two", list[1]);
    try std.testing.expectEqual(@as(i64, 9), try config.get(i64, arena, std.testing.io, path, "shared.untouched"));
}

test "config: a change that sets three keys in two tables runs once and every key reads back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const calls: *usize = try arena.create(usize);
    calls.* = 0;

    try config.update(arena, std.testing.io, path, MultiSet{ .calls = calls });
    try std.testing.expectEqual(@as(usize, 1), calls.*);
    try std.testing.expectEqual(@as(i64, 1), try config.get(i64, arena, std.testing.io, path, "a.one"));
    try std.testing.expectEqual(@as(i64, 2), try config.get(i64, arena, std.testing.io, path, "a.two"));
    try std.testing.expectEqual(@as(i64, 3), try config.get(i64, arena, std.testing.io, path, "b.three"));
}

test "config: a change that fails leaves the bytes unchanged, and a change that sets nothing changes nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);
    try writeFile(path, "kept = 1\n");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Refused, config.update(arena, std.testing.io, path, SetThenFail{}));
    try std.testing.expectEqualStrings("kept = 1\n", try fileText(arena, path));

    try config.update(arena, std.testing.io, path, DoNothing{});
    try std.testing.expectEqualStrings("kept = 1\n", try fileText(arena, path));
}

test "config: a change that asks for the wrong type fails with SettingWrongType" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);
    try writeFile(path, "count = \"text\"\n");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.SettingWrongType, config.update(arena_state.allocator(), std.testing.io, path, GetAsInt{}));
}

test "config: two threads appending to one list keep every item" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var first_errors: ?anyerror = null;
    var second_errors: ?anyerror = null;
    const first = try std.Thread.spawn(.{}, appendThread, .{ path, "first", &first_errors });
    const second = try std.Thread.spawn(.{}, appendThread, .{ path, "second", &second_errors });
    first.join();
    second.join();
    try std.testing.expect(first_errors == null);
    try std.testing.expect(second_errors == null);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const list = (try config.get(?[]const []const u8, arena_state.allocator(), std.testing.io, path, "shared.items")).?;
    try std.testing.expectEqual(@as(usize, 200), list.len);
}

test "config: two writers of different keys both keep every change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var first_errors: ?anyerror = null;
    var second_errors: ?anyerror = null;
    const first = try std.Thread.spawn(.{}, writerThread, .{ path, "first", &first_errors });
    const second = try std.Thread.spawn(.{}, writerThread, .{ path, "second", &second_errors });
    first.join();
    second.join();
    try std.testing.expect(first_errors == null);
    try std.testing.expect(second_errors == null);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var number: usize = 0;
    while (number < 100) : (number += 1) {
        const first_key = try std.fmt.allocPrint(arena, "first.k{d}", .{number});
        const second_key = try std.fmt.allocPrint(arena, "second.k{d}", .{number});
        try std.testing.expectEqual(@as(i64, @intCast(number)), try config.get(i64, arena, std.testing.io, path, first_key));
        try std.testing.expectEqual(@as(i64, @intCast(number)), try config.get(i64, arena, std.testing.io, path, second_key));
    }
}

test "config: every allocation failure of parse, edit, get, set and update is returned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);
    try writeFile(path, "a = 1\n");

    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkParse, .{path});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkEdit, .{path});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkGet, .{path});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSet, .{path});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkUpdate, .{path});
}

//
// Parses the file, letting an allocation failure out.
//
fn checkParse(allocator: std.mem.Allocator, path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    _ = try config.parse(arena_state.allocator(), .{ .path = path, .text = "a = 1\n" });
}

//
// Edits two sets of values, letting an allocation failure out.
//
fn checkEdit(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = path;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var old_values: std.json.ObjectMap = .empty;
    try old_values.put(arena, "a", .{ .integer = 1 });
    var new_values: std.json.ObjectMap = .empty;
    try new_values.put(arena, "a", .{ .integer = 2 });
    _ = try config.edit(arena, .{ .text = "a = 1\n", .old_values = old_values, .new_values = new_values });
}

//
// Reads a value, letting an allocation failure out.
//
fn checkGet(allocator: std.mem.Allocator, path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    _ = try config.get(?i64, arena_state.allocator(), std.testing.io, path, "a");
}

//
// Writes a value, letting an allocation failure out.
//
fn checkSet(allocator: std.mem.Allocator, path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    try config.set(arena_state.allocator(), std.testing.io, path, "b", @as(i64, 2));
}

//
// Runs a change, letting an allocation failure out.
//
fn checkUpdate(allocator: std.mem.Allocator, path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    try config.update(arena_state.allocator(), std.testing.io, path, SetOne{});
}

//
// Appends its items to `shared.items` from a thread with an allocator and an Io of its own.
//
fn appendThread(path: []const u8, prefix: []const u8, failure: *?anyerror) void {
    var thread_allocator: utils.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var number: usize = 0;
    while (number < 100) : (number += 1) {
        const item = std.fmt.allocPrint(arena, "{s} {d}", .{ prefix, number }) catch @panic("out of memory building an item");
        config.update(arena, io, path, ListAppend{ .item = item }) catch |err| {
            failure.* = err;
            return;
        };
    }
}

//
// Sets 100 keys of its own from a thread with an allocator and an Io of its own.
//
fn writerThread(path: []const u8, prefix: []const u8, failure: *?anyerror) void {
    var thread_allocator: utils.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var number: usize = 0;
    while (number < 100) : (number += 1) {
        const key = std.fmt.allocPrint(arena, "{s}.k{d}", .{ prefix, number }) catch @panic("out of memory building a key");
        config.set(arena, io, path, key, @as(i64, @intCast(number))) catch |err| {
            failure.* = err;
            return;
        };
    }
}

//
// Appends one item to the list `shared.items`.
//
const ListAppend = struct {
    // The item to append.
    item: []const u8,

    //
    // Reads the list, appends the item and writes the list back.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: config.Values) !void {
        var items: std.ArrayList([]const u8) = .empty;
        if (try values.get(?[]const []const u8, "shared.items")) |existing| {
            for (existing) |item| {
                try items.append(arena, item);
            }
        }
        try items.append(arena, self.item);
        try values.set("shared.items", items.items);
    }
};

//
// Sets three keys in two tables, counting its runs.
//
const MultiSet = struct {
    // How many times the change ran.
    calls: *usize,

    //
    // Sets the keys.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: config.Values) !void {
        _ = arena;
        self.calls.* += 1;
        try values.set("a.one", @as(i64, 1));
        try values.set("a.two", @as(i64, 2));
        try values.set("b.three", @as(i64, 3));
    }
};

//
// Sets one key and then fails.
//
const SetThenFail = struct {
    //
    // Sets and fails.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: config.Values) !void {
        _ = self;
        _ = arena;
        try values.set("written", @as(i64, 1));
        return error.Refused;
    }
};

//
// Makes no write at all.
//
const DoNothing = struct {
    //
    // Reads one value and writes nothing.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: config.Values) !void {
        _ = self;
        _ = arena;
        _ = try values.get(i64, "kept");
    }
};

//
// Asks for a value of the wrong type.
//
const GetAsInt = struct {
    //
    // Reads a key as an integer.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: config.Values) !void {
        _ = self;
        _ = arena;
        _ = try values.get(i64, "count");
    }
};

//
// Sets one key.
//
const SetOne = struct {
    //
    // Sets the key.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: config.Values) !void {
        _ = self;
        _ = arena;
        try values.set("b", @as(i64, 2));
    }
};

//
// Writes a file.
//
fn writeFile(path: []const u8, text: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = text });
}

//
// Reads a file's text.
//
fn fileText(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1024 * 1024));
}
