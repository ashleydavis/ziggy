const std = @import("std");
const builtin = @import("builtin");
const utils = @import("ziggy").task_queue.utils;
const temp_dir = utils.temp_dir;
const process_env = utils.process_env;

//
// Gives the temporary directory with the environment holding only the variables given.
//
fn tmpDirWith(names_and_values: []const [2][]const u8) ![]const u8 {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    for (names_and_values) |pair| {
        try environ_map.put(pair[0], pair[1]);
    }
    process_env.setEnvironMap(&environ_map);
    defer process_env.setEnvironMap(null);
    return temp_dir.osTmpDir(std.testing.allocator);
}

test "osTmpDir takes the first variable that is set, without its trailing separator" {
    if (builtin.os.tag == .windows) {
        const from_temp = try tmpDirWith(&.{ .{ "TMP", "C:\\Other" }, .{ "TEMP", "C:\\Temp\\" } });
        defer std.testing.allocator.free(from_temp);
        try std.testing.expectEqualStrings("C:\\Temp", from_temp);
        const root = try tmpDirWith(&.{.{ "TEMP", "D:\\" }});
        defer std.testing.allocator.free(root);
        try std.testing.expectEqualStrings("D:\\", root);
    }
    else {
        const from_tmpdir = try tmpDirWith(&.{ .{ "TEMP", "/other" }, .{ "TMPDIR", "/var/tmp/" } });
        defer std.testing.allocator.free(from_tmpdir);
        try std.testing.expectEqualStrings("/var/tmp", from_tmpdir);
        const from_tmp = try tmpDirWith(&.{ .{ "TMPDIR", "" }, .{ "TMP", "/scratch" } });
        defer std.testing.allocator.free(from_tmp);
        try std.testing.expectEqualStrings("/scratch", from_tmp);
    }
}

test "osTmpDir falls back to the system's directory when no variable is set" {
    if (builtin.os.tag == .windows) {
        const from_root = try tmpDirWith(&.{.{ "SystemRoot", "C:\\Windows" }});
        defer std.testing.allocator.free(from_root);
        try std.testing.expectEqualStrings("C:\\Windows\\temp", from_root);
        try std.testing.expectError(error.NoTemporaryDirectory, tmpDirWith(&.{}));
    }
    else {
        const fallback = try tmpDirWith(&.{});
        defer std.testing.allocator.free(fallback);
        try std.testing.expectEqualStrings("/tmp", fallback);
    }
}
