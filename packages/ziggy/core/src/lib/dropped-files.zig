//
// The files the user last dropped on the window, as the native app reported them. A frontend cannot learn the path of a dropped
// file: a web view gives it no File with a path (WebKitGTK gives no File at all), so the frontend sends the core a get-dropped-paths message for the paths of the last drop.
//
// The native app's thread checks a drop's paths (see `check`) and the main thread, which owns the last drop, records the result.
//

const std = @import("std");

//
// One dropped file.
//
pub const DroppedFile = struct {
    // The file's name, without its folder.
    name: []const u8,
    // The file's full path.
    path: []const u8,
    // The file's size in bytes when it was dropped.
    size: u64,
};

//
// Checks a drop on the calling thread: the paths are the JSON text of an array of strings, each of which must be a file that can be
// read. Returns the JSON text of the dropped files (an array of DroppedFile), allocated with the allocator, for the main thread to
// record. A path that is not such a file, or text that is not such an array, is an error.
//
pub fn check(allocator: std.mem.Allocator, io: std.Io, paths_json: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, paths_json, .{});
    if (parsed != .array) {
        return error.NotAnArrayOfPaths;
    }
    var files: std.ArrayList(DroppedFile) = .empty;
    for (parsed.array.items) |item| {
        if (item != .string) {
            return error.NotAnArrayOfPaths;
        }
        const stat = try std.Io.Dir.cwd().statFile(io, item.string, .{});
        try files.append(arena, .{
            .name = std.fs.path.basename(item.string),
            .path = item.string,
            .size = stat.size,
        });
    }
    return try std.json.Stringify.valueAlloc(allocator, files.items, .{});
}

//
//
// The last drop. A new drop replaces the one before it. Used only on the main thread, whose allocator each function that allocates is
// given.
//
pub const DroppedFiles = struct {
    // The files of the last drop, as the JSON text `check` returned, or null when nothing was dropped.
    files_json: ?[]u8,

    pub const empty: DroppedFiles = .{
        .files_json = null,
    };

    //
    // Frees the last drop, with the allocator it was recorded with.
    //
    pub fn deinit(self: *DroppedFiles, allocator: std.mem.Allocator) void {
        if (self.files_json) |text| {
            allocator.free(text);
        }
    }

    //
    // Records a drop that `check` has checked, replacing the last one. The files are the JSON text `check` returned, which is copied.
    //
    pub fn record(self: *DroppedFiles, allocator: std.mem.Allocator, files_json: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        _ = try std.json.parseFromSliceLeaky([]const DroppedFile, arena_state.allocator(), files_json, .{});
        const copy = try allocator.dupe(u8, files_json);
        self.deinit(allocator);
        self.files_json = copy;
    }

    //
    // Checks and records a drop on the calling thread, which owns the drop, as the test control connection's drop does on the main
    // thread. The paths are the JSON text of an array of strings.
    //
    pub fn replace(self: *DroppedFiles, io: std.Io, allocator: std.mem.Allocator, paths_json: []const u8) !void {
        const files_json = try check(allocator, io, paths_json);
        defer allocator.free(files_json);
        try self.record(allocator, files_json);
    }

    //
    // The paths of the last drop as the JSON text of an array of strings, allocated with the allocator, [] when nothing was dropped.
    //
    pub fn pathsJson(self: *DroppedFiles, allocator: std.mem.Allocator) ![]u8 {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const files = if (self.files_json) |text| try std.json.parseFromSliceLeaky([]const DroppedFile, arena, text, .{}) else &.{};
        var paths: std.ArrayList([]const u8) = .empty;
        for (files) |file| {
            try paths.append(arena, file.path);
        }
        return try std.json.Stringify.valueAlloc(allocator, paths.items, .{});
    }
};
