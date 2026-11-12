//
// The state file: parsing it, reading and writing keys, keeping the bytes of an unreadable file, and the atomic updates that make writers
// take turns.
//

const std = @import("std");
const state = @import("config_state").state;
const utils = @import("utils");

test "state: every type round trips through the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "state.json" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    const Settings = struct { sidebar: struct { open: bool } };
    const Item = struct { name: []const u8 };

    try state.set(arena, io, path, "flag", true);
    try state.set(arena, io, path, "count", @as(i64, 12));
    try state.set(arena, io, path, "ratio", @as(f64, 0.5));
    try state.set(arena, io, path, "name", "remembered");
    try state.set(arena, io, path, "settings", Settings{ .sidebar = .{ .open = true } });
    try state.set(arena, io, path, "items", &[_]Item{ .{ .name = "one" }, .{ .name = "two" } });
    try state.set(arena, io, path, "removed", @as(?i64, null));

    try std.testing.expect(try state.get(bool, arena, io, path, "flag"));
    try std.testing.expectEqual(@as(i64, 12), try state.get(i64, arena, io, path, "count"));
    try std.testing.expectEqual(@as(f64, 0.5), try state.get(f64, arena, io, path, "ratio"));
    try std.testing.expectEqualStrings("remembered", try state.get([]const u8, arena, io, path, "name"));
    try std.testing.expect((try state.get(Settings, arena, io, path, "settings")).sidebar.open);
    const items = try state.get([]const Item, arena, io, path, "items");
    try std.testing.expectEqualStrings("two", items[1].name);
    try std.testing.expectEqual(@as(?i64, null), try state.get(?i64, arena, io, path, "removed"));

    const text = try fileText(arena, path);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n  ") != null);
}

test "state: a missing key is null for an optional type and an error otherwise" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "state.json" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(?i64, null), try state.get(?i64, arena, std.testing.io, path, "missing"));
    try std.testing.expectError(error.Thrown, state.get(i64, arena, std.testing.io, path, "missing"));
}

test "state: a value of the wrong type is named" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "state.json" });
    defer std.testing.allocator.free(path);
    try writeFile(path, "{\"count\":\"text\"}");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.SettingWrongType, state.get(i64, arena_state.allocator(), std.testing.io, path, "count"));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "state") != null);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "a string") != null);
}

test "state: an unreadable file's bytes are kept beside it by the first write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "state.json" });
    defer std.testing.allocator.free(path);
    try writeFile(path, "not json");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try state.set(arena, std.testing.io, path, "a", @as(i64, 1));
    try std.testing.expectEqual(@as(i64, 1), try state.get(i64, arena, std.testing.io, path, "a"));
    const backups = try backupNames(arena, directory_path);
    try std.testing.expectEqual(@as(usize, 1), backups.len);
    try std.testing.expectEqualStrings("not json", try fileText(arena, backups[0]));

    try writeFile(path, "also not json");
    try state.set(arena, std.testing.io, path, "b", @as(i64, 2));
    const more_backups = try backupNames(arena, directory_path);
    try std.testing.expectEqual(@as(usize, 2), more_backups.len);
}

test "state: parse reports text that is not JSON and JSON that is not an object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const not_json = try state.parse(arena, "not json");
    try std.testing.expectEqual(@as(usize, 0), not_json.values.count());
    try std.testing.expect(std.mem.indexOf(u8, not_json.problem.?, "it is not JSON") != null);

    const not_object = try state.parse(arena, "[1, 2]");
    try std.testing.expectEqualStrings("it holds JSON that is not an object", not_object.problem.?);

    const good = try state.parse(arena, "{\"a\":1}");
    try std.testing.expect(good.problem == null);
    try std.testing.expectEqual(@as(i64, 1), good.values.get("a").?.integer);
}

test "state: status is missing, present and unreadable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "state.json" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect((try state.status(arena, std.testing.io, path)) == .missing);
    try writeFile(path, "{\"a\":1}");
    try std.testing.expect((try state.status(arena, std.testing.io, path)) == .present);
    try writeFile(path, "not json");
    const unreadable = try state.status(arena, std.testing.io, path);
    try std.testing.expect(unreadable == .unreadable);
    try std.testing.expect(std.mem.indexOf(u8, unreadable.unreadable, "it is not JSON") != null);
}

test "state: a file over the limit reads as a problem and refuses a write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "state.json" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const big = try arena.alloc(u8, state.read_limit_bytes + 1);
    @memset(big, 'a');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "state.json", .data = big });

    const read_result = try state.read(arena, std.testing.io, path);
    try std.testing.expectEqual(@as(usize, 0), read_result.values.count());
    try std.testing.expect(std.mem.indexOf(u8, read_result.problem.?, "larger than 16 MiB") != null);

    try std.testing.expectError(error.FileTooLarge, state.set(arena, std.testing.io, path, "a", @as(i64, 1)));
    const bytes = try fileText(arena, path);
    try std.testing.expectEqual(@as(usize, big.len), bytes.len);
}

test "state: writing a float that is not finite fails and leaves the file unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "state.json" });
    defer std.testing.allocator.free(path);
    try writeFile(path, "{\"kept\":1}");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.Thrown, state.set(arena, std.testing.io, path, "ratio", std.math.nan(f64)));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "ratio") != null);
    try std.testing.expectEqualStrings("{\"kept\":1}", try fileText(arena, path));
}

test "state: two threads appending to one list keep every item" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "state.json" });
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
    const list = (try state.get(?[]const []const u8, arena_state.allocator(), std.testing.io, path, "shared.items")).?;
    try std.testing.expectEqual(@as(usize, 200), list.len);
}

test "state: two writers of different keys both keep every change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "state.json" });
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
        try std.testing.expectEqual(@as(i64, @intCast(number)), try state.get(i64, arena, std.testing.io, path, first_key));
        try std.testing.expectEqual(@as(i64, @intCast(number)), try state.get(i64, arena, std.testing.io, path, second_key));
    }
}

test "state: every allocation failure of parse, get, set and update is returned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "state.json" });
    defer std.testing.allocator.free(path);
    try writeFile(path, "{\"a\":1}");

    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkParse, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkGet, .{path});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSet, .{path});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkUpdate, .{path});
}

//
// Parses text, letting an allocation failure out.
//
fn checkParse(allocator: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    _ = try state.parse(arena_state.allocator(), "{\"a\":1}");
}

//
// Reads a value, letting an allocation failure out.
//
fn checkGet(allocator: std.mem.Allocator, path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    _ = try state.get(?i64, arena_state.allocator(), std.testing.io, path, "a");
}

//
// Writes a value, letting an allocation failure out.
//
fn checkSet(allocator: std.mem.Allocator, path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    try state.set(arena_state.allocator(), std.testing.io, path, "b", @as(i64, 2));
}

//
// Runs a change, letting an allocation failure out.
//
fn checkUpdate(allocator: std.mem.Allocator, path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    try state.update(arena_state.allocator(), std.testing.io, path, SetOne{});
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
        state.update(arena, io, path, ListAppend{ .item = item }) catch |err| {
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
        state.set(arena, io, path, key, @as(i64, @intCast(number))) catch |err| {
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
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: state.Values) !void {
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
// Sets one key.
//
const SetOne = struct {
    //
    // Sets the key.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: state.Values) !void {
        _ = self;
        _ = arena;
        try values.set("b", @as(i64, 2));
    }
};

//
// The paths of the copies the writes kept of an unreadable file, in the directory.
//
fn backupNames(arena: std.mem.Allocator, directory_path: []const u8) ![]const []const u8 {
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, directory_path, .{ .iterate = true });
    defer directory.close(std.testing.io);
    var walker = try directory.walk(arena);
    defer walker.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        if (std.mem.indexOf(u8, entry.path, ".unreadable-") != null) {
            try names.append(arena, try std.fs.path.join(arena, &.{ directory_path, entry.path }));
        }
    }
    return names.items;
}

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
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(64 * 1024 * 1024));
}
