const std = @import("std");
const watch = @import("../lib/watch.zig");

test "build outputs, caches, dependencies and hidden directories are left out of a watch" {
    for ([_][]const u8{ "zig-out", ".zig-cache", "node_modules", ".git", "dist", "dist-build.a1B2c3", "tmp", "build" }) |name| {
        try std.testing.expect(watch.isSkippedDirectory(name));
    }
    for ([_][]const u8{ "backend", "ui", "src", "lib" }) |name| {
        try std.testing.expect(!watch.isSkippedDirectory(name));
    }
}

test "only Zig sources and build.zig.zon are watched" {
    try std.testing.expect(watch.isWatchedFile("handlers.zig"));
    try std.testing.expect(watch.isWatchedFile("build.zig.zon"));
    try std.testing.expect(!watch.isWatchedFile("main.ts"));
    try std.testing.expect(!watch.isWatchedFile("index.html"));
}

test "a tree's sum changes when a counted file is added, saved or removed, and not when an uncounted one is" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{
        .iterate = true,
    });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/a.zig",
        .data = "const a = 1;",
    });
    const first = try watch.treeSignature(io, std.testing.allocator, tmp.dir);
    try std.testing.expectEqual(first, try watch.treeSignature(io, std.testing.allocator, tmp.dir));

    try tmp.dir.writeFile(io, .{
        .sub_path = "src/notes.txt",
        .data = "not Zig",
    });
    try std.testing.expectEqual(first, try watch.treeSignature(io, std.testing.allocator, tmp.dir));

    try tmp.dir.writeFile(io, .{
        .sub_path = "src/a.zig",
        .data = "const a = 22;",
    });
    const saved = try watch.treeSignature(io, std.testing.allocator, tmp.dir);
    try std.testing.expect(saved != first);

    try tmp.dir.writeFile(io, .{
        .sub_path = "src/b.zig",
        .data = "const b = 2;",
    });
    const added = try watch.treeSignature(io, std.testing.allocator, tmp.dir);
    try std.testing.expect(added != saved);

    try tmp.dir.deleteFile(io, "src/b.zig");
    try std.testing.expectEqual(saved, try watch.treeSignature(io, std.testing.allocator, tmp.dir));
}

test "a file under a skipped directory does not change the sum" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{
        .iterate = true,
    });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "a.zig",
        .data = "const a = 1;",
    });
    const first = try watch.treeSignature(io, std.testing.allocator, tmp.dir);
    try tmp.dir.createDirPath(io, ".zig-cache/o");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".zig-cache/o/generated.zig",
        .data = "const generated = 1;",
    });
    try tmp.dir.createDirPath(io, "zig-out");
    try tmp.dir.writeFile(io, .{
        .sub_path = "zig-out/out.zig",
        .data = "const out = 1;",
    });
    try std.testing.expectEqual(first, try watch.treeSignature(io, std.testing.allocator, tmp.dir));
}
