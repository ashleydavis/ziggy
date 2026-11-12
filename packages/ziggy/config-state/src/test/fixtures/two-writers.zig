//
// Proves that two processes writing different keys of one config file at once both keep every change, which a unit test cannot do because it
// runs in one process.
//
// With `write <config path> <prefix>` it reads its stdin until end of file and then sets 100 keys of its own. With `<directory>` it starts
// two copies of itself, releases them together by closing both stdins, waits for both and reads every one of the 200 keys back.
//

const std = @import("std");
const config_state = @import("config_state");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(allocator);

    if (all_args.len >= 4 and std.mem.eql(u8, all_args[1], "write")) {
        try writeKeys(init, all_args[2], all_args[3]);
        return;
    }
    if (all_args.len >= 2) {
        try runBoth(init, all_args[1]);
        return;
    }
    std.debug.print("Usage: two-writers <directory>, or two-writers write <config path> <prefix>\n", .{});
    std.process.exit(2);
}

//
// Reads stdin to its end, which is how the parent releases both writers together, then sets 100 keys of its own.
//
fn writeKeys(init: std.process.Init, path: []const u8, prefix: []const u8) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buffer);
    _ = try reader.interface.allocRemaining(allocator, .limited(1024));

    var number: usize = 0;
    while (number < 100) : (number += 1) {
        var arena_state = std.heap.ArenaAllocator.init(init.gpa);
        defer arena_state.deinit();
        {
            const arena = arena_state.allocator();
            const key = try std.fmt.allocPrint(arena, "{s}.k{d}", .{ prefix, number });
            try config_state.config.set(arena, io, path, key, @as(i64, @intCast(number)));
        }
    }
}

//
// Starts both writers, releases them together, waits for both and reads every key back.
//
fn runBoth(init: std.process.Init, directory: []const u8) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const path = try std.fs.path.join(allocator, &.{ directory, "config.toml" });
    const executable = try std.process.executablePathAlloc(io, allocator);

    var children: [2]std.process.Child = undefined;
    children[0] = try std.process.spawn(io, .{
        .argv = &.{ executable, "write", path, "first" },
        .stdin = .pipe,
    });
    children[1] = try std.process.spawn(io, .{
        .argv = &.{ executable, "write", path, "second" },
        .stdin = .pipe,
    });
    // Closing both stdins only now lets the two start together, with no sleep.
    for (&children) |*child| {
        child.stdin.?.close(io);
        child.stdin = null;
    }
    for (&children, 0..) |*child, index| {
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    std.debug.print("The {s} writer exited with {d}.\n", .{ if (index == 0) "first" else "second", code });
                    std.process.exit(1);
                }
            },
            else => {
                std.debug.print("The {s} writer did not exit normally.\n", .{if (index == 0) "first" else "second"});
                std.process.exit(1);
            },
        }
    }

    var missing = false;
    var number: usize = 0;
    while (number < 100) : (number += 1) {
        const prefixes = [2][]const u8{ "first", "second" };
        for (prefixes) |prefix| {
            const key = try std.fmt.allocPrint(allocator, "{s}.k{d}", .{ prefix, number });
            const value = config_state.config.get(?i64, allocator, io, path, key) catch |err| {
                std.debug.print("Reading {s} failed: {s}\n", .{ key, @errorName(err) });
                missing = true;
                continue;
            };
            if (value != @as(?i64, @intCast(number))) {
                std.debug.print("{s} is {?d}, not {d}.\n", .{ key, value, number });
                missing = true;
            }
        }
    }
    if (missing) {
        std.process.exit(1);
    }
}
