const std = @import("std");
const pickers = @import("../lib/pickers.zig");

test "the kinds of dialog are numbered as ziggy.h numbers them, and any other number is none" {
    try std.testing.expectEqual(pickers.Kind.open_files, pickers.kindFromInt(0).?);
    try std.testing.expectEqual(pickers.Kind.save_file, pickers.kindFromInt(1).?);
    try std.testing.expectEqual(pickers.Kind.folder, pickers.kindFromInt(2).?);
    try std.testing.expect(pickers.kindFromInt(3) == null);
    try std.testing.expect(pickers.kindFromInt(-1) == null);
}

test "a dialog to open files lets several be chosen, one path to a line, under the title given" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = try pickers.zenityArgv(arena.allocator(), .open_files, "Pick photos", null);
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("zenity", argv[0]);
    try std.testing.expectEqualStrings("--file-selection", argv[1]);
    try std.testing.expectEqualStrings("--title=Pick photos", argv[2]);
    try std.testing.expectEqualStrings("--multiple", argv[3]);
    try std.testing.expectEqualStrings("--separator=\n", argv[4]);
}

test "a dialog to save suggests the initial name, and a folder dialog chooses folders" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const save = try pickers.zenityArgv(arena.allocator(), .save_file, null, "notes.txt");
    try std.testing.expectEqual(@as(usize, 5), save.len);
    try std.testing.expectEqualStrings("--title=Save As", save[2]);
    try std.testing.expectEqualStrings("--save", save[3]);
    try std.testing.expectEqualStrings("--filename=notes.txt", save[4]);

    const folder = try pickers.zenityArgv(arena.allocator(), .folder, null, "ignored.txt");
    try std.testing.expectEqual(@as(usize, 4), folder.len);
    try std.testing.expectEqualStrings("--title=Select Folder", folder[2]);
    try std.testing.expectEqualStrings("--directory", folder[3]);
}

test "a dialog to open files has its own default title" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = try pickers.zenityArgv(arena.allocator(), .open_files, null, null);
    try std.testing.expectEqualStrings("--title=Select Files", argv[2]);
}

test "the paths printed one to a line become a JSON array, without empty lines or carriage returns" {
    const json = try pickers.pathsJsonFromOutput(std.testing.allocator, "/home/a/one.jpg\n/home/a/two \"photos\"/two.jpg\r\n\n");
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[\"/home/a/one.jpg\",\"/home/a/two \\\"photos\\\"/two.jpg\"]", json);
}

test "nothing printed is an empty array" {
    const json = try pickers.pathsJsonFromOutput(std.testing.allocator, "");
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[]", json);
}
