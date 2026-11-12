//
// Where the config file lives on every platform, worked out from the app's names and the environment.
//

const std = @import("std");
const platform_lib = @import("platform.zig");
const Platform = platform_lib.Platform;
const AppNames = platform_lib.AppNames;
const utils = @import("utils");
const errors = utils.errors;

//
// The environment the config file's rule reads. A test fills it in, and a running app reads it from its process environment.
//
pub const Variables = struct {
    // `<NAME>_CONFIG_DIR`, which names the directory of the config file instead of the platform's rule.
    config_dir_override: ?[]const u8 = null,
    // `HOME` on Linux and macOS.
    home: ?[]const u8 = null,
    // `CFFIXED_USER_HOME` on macOS, which wins over `HOME` when it is not empty.
    cf_fixed_user_home: ?[]const u8 = null,
    // `XDG_CONFIG_HOME`, which wins over the home directory on Linux and macOS.
    xdg_config_home: ?[]const u8 = null,
    // `APPDATA` on Windows, which holds the config file's directory.
    app_data: ?[]const u8 = null,
};

//
// The path of the config file for a platform and the variables it reads. A non-empty override names the directory and no other
// variable is read. On a phone the file lives in the app's data directory.
//
pub fn path(
    arena: std.mem.Allocator,
    platform: Platform,
    names: AppNames,
    variables: Variables,
    data_dir: []const u8,
) ![]const u8 {
    std.debug.assert(names.name.len > 0);
    std.debug.assert(names.title.len > 0);

    if (platform_lib.nonEmpty(variables.config_dir_override)) |directory| {
        return platform_lib.join(arena, platform_lib.separator(platform), &.{ directory, "config.toml" });
    }
    if (platform == .android or platform == .ios) {
        std.debug.assert(data_dir.len > 0);
        return platform_lib.join(arena, "/", &.{ data_dir, "config.toml" });
    }
    return desktopPath(arena, platform, names, variables);
}

//
// The config file's path on a desktop platform.
//
fn desktopPath(
    arena: std.mem.Allocator,
    platform: Platform,
    names: AppNames,
    variables: Variables,
) ![]const u8 {
    switch (platform) {
        .linux, .macos => {
            const config_home = if (platform_lib.nonEmpty(variables.xdg_config_home)) |xdg_config_home|
                xdg_config_home
            else blk: {
                const home: []const u8 = home_directory: {
                    if (platform == .macos) {
                        if (platform_lib.nonEmpty(variables.cf_fixed_user_home)) |fixed_home| {
                            break :home_directory fixed_home;
                        }
                    }
                    if (platform_lib.nonEmpty(variables.home)) |found_home| {
                        break :home_directory found_home;
                    }
                    if (platform == .macos) {
                        return errors.throwError("Cannot find where the config file goes: neither XDG_CONFIG_HOME, CFFIXED_USER_HOME nor HOME is set.", .{});
                    }
                    return errors.throwError("Cannot find where the config file goes: neither XDG_CONFIG_HOME nor HOME is set.", .{});
                };
                break :blk try platform_lib.join(arena, "/", &.{ home, ".config" });
            };
            return platform_lib.join(arena, "/", &.{ config_home, names.name, "config.toml" });
        },
        .windows => {
            const app_data = platform_lib.nonEmpty(variables.app_data) orelse
                return errors.throwError("Cannot find where the config file goes: APPDATA is not set.", .{});
            return platform_lib.join(arena, "\\", &.{ app_data, names.title, "config.toml" });
        },
        .android, .ios => unreachable,
    }
}
