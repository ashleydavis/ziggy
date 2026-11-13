//
// Where the state file lives on every platform, worked out from the app's names and the environment.
//

const std = @import("std");
const platform_lib = @import("platform.zig");
const Platform = platform_lib.Platform;
const AppNames = platform_lib.AppNames;
const utils = @import("utils");
const errors = utils.errors;

//
// The environment the state file's rule reads. A test fills it in, and a running app reads it from its process environment.
//
pub const Variables = struct {
    // `<NAME>_STATE_DIR`, which names the directory of the state file instead of the platform's rule.
    state_dir_override: ?[]const u8 = null,
    // `HOME` on Linux and macOS.
    home: ?[]const u8 = null,
    // `CFFIXED_USER_HOME` on macOS, which wins over `HOME` when it is not empty.
    cf_fixed_user_home: ?[]const u8 = null,
    // `XDG_STATE_HOME`, which wins over the home directory on Linux.
    xdg_state_home: ?[]const u8 = null,
    // `LOCALAPPDATA` on Windows, which holds the state file's directory.
    local_app_data: ?[]const u8 = null,
};

//
// The path of the state file for a platform and the variables it reads. A non-empty override names the directory and no other
// variable is read. On a mobile the file lives in the app's data directory.
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

    if (platform_lib.nonEmpty(variables.state_dir_override)) |directory| {
        return platform_lib.join(arena, platform_lib.separator(platform), &.{ directory, "state.json" });
    }
    if (platform == .android or platform == .ios) {
        std.debug.assert(data_dir.len > 0);
        return platform_lib.join(arena, "/", &.{ data_dir, "state.json" });
    }
    return desktopPath(arena, platform, names, variables);
}

//
// The state file's path on a desktop platform.
//
fn desktopPath(
    arena: std.mem.Allocator,
    platform: Platform,
    names: AppNames,
    variables: Variables,
) ![]const u8 {
    switch (platform) {
        .linux => {
            const state_home = if (platform_lib.nonEmpty(variables.xdg_state_home)) |xdg_state_home|
                xdg_state_home
            else blk: {
                const home = try platform_lib.homeDirectory(platform, variables.home, variables.cf_fixed_user_home, "state");
                break :blk try platform_lib.join(arena, "/", &.{ home, ".local", "state" });
            };
            return platform_lib.join(arena, "/", &.{ state_home, names.name, "state.json" });
        },
        .macos => {
            const home = try platform_lib.homeDirectory(platform, variables.home, variables.cf_fixed_user_home, "state");
            return platform_lib.join(arena, "/", &.{ home, "Library", "Application Support", names.title, "state.json" });
        },
        .windows => {
            const local_app_data = platform_lib.nonEmpty(variables.local_app_data) orelse
                return errors.throwError("Cannot find where the state file goes: LOCALAPPDATA is not set.", .{});
            return platform_lib.join(arena, "\\", &.{ local_app_data, names.title, "state.json" });
        },
        .android, .ios => unreachable,
    }
}
