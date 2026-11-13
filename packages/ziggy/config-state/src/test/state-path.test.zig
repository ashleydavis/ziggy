//
// The state file's path on every platform, and the failure when a variable its rule needs is missing.
//

const std = @import("std");
const config_state = @import("config_state");
const state_path = config_state.state_path;
const platform_lib = config_state.platform;
const utils = @import("utils");

const names: platform_lib.AppNames = .{
    .name = "ziggy-app",
    .title = "Ziggy App",
};

test "state path: linux takes XDG_STATE_HOME when it is set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try state_path.path(arena, .linux, names, .{
        .home = "/home/ash",
        .xdg_state_home = "/home/ash/remembered",
    }, "");
    try std.testing.expectEqualStrings("/home/ash/remembered/ziggy-app/state.json", found);
}

test "state path: linux falls back to the home directory when XDG_STATE_HOME is empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try state_path.path(arena, .linux, names, .{
        .home = "/home/ash",
        .xdg_state_home = "",
    }, "");
    try std.testing.expectEqualStrings("/home/ash/.local/state/ziggy-app/state.json", found);
}

test "state path: macos takes CFFIXED_USER_HOME before HOME" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try state_path.path(arena, .macos, names, .{
        .home = "/Users/ash",
        .cf_fixed_user_home = "/Users/fixed",
    }, "");
    try std.testing.expectEqualStrings("/Users/fixed/Library/Application Support/Ziggy App/state.json", found);
}

test "state path: windows uses the app's title" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try state_path.path(arena, .windows, names, .{
        .local_app_data = "C:\\Users\\ash\\AppData\\Local",
    }, "");
    try std.testing.expectEqualStrings("C:\\Users\\ash\\AppData\\Local\\Ziggy App\\state.json", found);
}

test "state path: the override wins on every platform and needs no other variable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]platform_lib.Platform{ .linux, .macos, .windows }) |platform| {
        const found = try state_path.path(arena, platform, names, .{
            .state_dir_override = "/chosen/state",
        }, "");
        if (platform == .windows) {
            try std.testing.expectEqualStrings("/chosen/state\\state.json", found);
        }
        else {
            try std.testing.expectEqualStrings("/chosen/state/state.json", found);
        }
    }
}

test "state path: a mobile keeps the file in the app's data directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]platform_lib.Platform{ .android, .ios }) |platform| {
        const found = try state_path.path(arena, platform, names, .{}, "/data/app/files");
        try std.testing.expectEqualStrings("/data/app/files/state.json", found);
    }
}

test "state path: each missing variable fails naming it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Thrown, state_path.path(arena, .linux, names, .{}, ""));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "HOME") != null);

    try std.testing.expectError(error.Thrown, state_path.path(arena, .windows, names, .{}, ""));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "LOCALAPPDATA") != null);

    try std.testing.expectError(error.Thrown, state_path.path(arena, .macos, names, .{}, ""));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "CFFIXED_USER_HOME") != null);
}
