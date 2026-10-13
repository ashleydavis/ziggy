//
// Watching the Zig files of the app and of Ziggy for the supervisor. A tree is summed into one number from the path, size and
// modification time of each Zig file, so a file added, removed or saved changes the number. The supervisor sums the trees again
// every so often and compares, which works the same on every operating system and needs nothing from one.
//

const std = @import("std");

//
// Whether a directory is left out of a watch: hidden directories (.git, .zig-cache) and the directories builds and package managers
// write to, so that a build's own output never looks like a change.
//
pub fn isSkippedDirectory(name: []const u8) bool {
    const skipped = [_][]const u8{
        "zig-out",
        "zig-pkg",
        "node_modules",
        "dist",
        "tmp",
        "build",
        "out",
        "release",
    };
    if (name.len > 0 and name[0] == '.') {
        return true;
    }
    if (std.mem.startsWith(u8, name, "dist-build.")) {
        return true;
    }
    for (skipped) |skipped_name| {
        if (std.mem.eql(u8, name, skipped_name)) {
            return true;
        }
    }
    return false;
}

//
// Whether a file is watched: Zig sources and the build's own files, whose change rebuilds the dev host.
//
pub fn isWatchedFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon");
}

//
// Sums the watched files of the tree under the directory. Two sums differ when a watched file was added, removed, renamed,
// resized or saved between them.
//
pub fn treeSignature(io: std.Io, allocator: std.mem.Allocator, root: std.Io.Dir) !u64 {
    var sum: u64 = 0;
    var walker = try root.walkSelectively(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (!isSkippedDirectory(entry.basename)) {
                    try walker.enter(io, entry);
                }
            },
            .file => {
                if (!isWatchedFile(entry.basename)) {
                    continue;
                }
                const stat = entry.dir.statFile(io, entry.basename, .{}) catch |err| switch (err) {
                    // Deleted between being listed and being looked at: the next sum sees it gone.
                    error.FileNotFound => continue,
                    else => return err,
                };
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(entry.path);
                hasher.update(std.mem.asBytes(&stat.size));
                hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
                // Added, so the order the directory lists its files in does not matter.
                sum +%= hasher.final();
            },
            else => {},
        }
    }
    return sum;
}
