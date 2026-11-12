//
// The config file's path on every platform, and the failure when a variable its rule needs is missing.
//

const std = @import("std");
const config_state = @import("config_state");
const config_path = config_state.config_path;
const platform_lib = config_state.platform;
const utils = @import("utils");

const names: platform_lib.AppNames = .{
    .name = "ziggy-app",
    .title = "Ziggy App",
};

test "config path: linux takes XDG_CONFIG_HOME when it is set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try config_path.path(arena, .linux, names, .{
        .home = "/home/ash",
        .xdg_config_home = "/home/ash/settings",
    }, "");
    try std.testing.expectEqualStrings("/home/ash/settings/ziggy-app/config.toml", found);
}

test "config path: linux falls back to the home directory when XDG_CONFIG_HOME is empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try config_path.path(arena, .linux, names, .{
        .home = "/home/ash",
        .xdg_config_home = "",
    }, "");
    try std.testing.expectEqualStrings("/home/ash/.config/ziggy-app/config.toml", found);
}

test "config path: macos takes CFFIXED_USER_HOME before HOME" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try config_path.path(arena, .macos, names, .{
        .home = "/Users/ash",
        .cf_fixed_user_home = "/Users/fixed",
    }, "");
    try std.testing.expectEqualStrings("/Users/fixed/.config/ziggy-app/config.toml", found);
}

test "config path: windows uses the app's title" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try config_path.path(arena, .windows, names, .{
        .app_data = "C:\\Users\\ash\\AppData\\Roaming",
    }, "");
    try std.testing.expectEqualStrings("C:\\Users\\ash\\AppData\\Roaming\\Ziggy App\\config.toml", found);
}

test "config path: the override wins on every platform and needs no other variable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]platform_lib.Platform{ .linux, .macos, .windows }) |platform| {
        const found = try config_path.path(arena, platform, names, .{
            .config_dir_override = "/chosen/config",
        }, "");
        if (platform == .windows) {
            try std.testing.expectEqualStrings("/chosen/config\\config.toml", found);
        }
        else {
            try std.testing.expectEqualStrings("/chosen/config/config.toml", found);
        }
    }
}

test "config path: a phone keeps the file in the app's data directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]platform_lib.Platform{ .android, .ios }) |platform| {
        const found = try config_path.path(arena, platform, names, .{}, "/data/app/files");
        try std.testing.expectEqualStrings("/data/app/files/config.toml", found);
    }
}

test "config path: each missing variable fails naming it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Thrown, config_path.path(arena, .linux, names, .{}, ""));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "XDG_CONFIG_HOME") != null);

    try std.testing.expectError(error.Thrown, config_path.path(arena, .windows, names, .{}, ""));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "APPDATA") != null);

    try std.testing.expectError(error.Thrown, config_path.path(arena, .macos, names, .{}, ""));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "CFFIXED_USER_HOME") != null);
}
