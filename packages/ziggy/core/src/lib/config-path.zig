//
// The config file's path for the running app, and for a program with no native app, from the process environment.
//

const std = @import("std");
const build_options = @import("build_options");
const config_state = @import("config_state");
const platform_lib = config_state.platform;
const config_path = config_state.config_path;
const utils = @import("utils");
const environment_variable = @import("environment-variable.zig");
const errors = utils.errors;

//
// The environment variable the config file's directory override is named by, such as MY_APP_CONFIG_DIR.
//
pub fn variableName(arena: std.mem.Allocator, names: platform_lib.AppNames) ![]const u8 {
    return platform_lib.variableName(arena, names, "_CONFIG_DIR");
}

//
// The path of the running app's config file, from its names, its data directory and the process environment.
//
pub fn appConfigPath(arena: std.mem.Allocator, names: platform_lib.AppNames, data_dir: []const u8) ![]const u8 {
    std.debug.assert(names.name.len > 0);
    std.debug.assert(names.title.len > 0);
    return config_path.path(arena, platform_lib.currentPlatform(), names, try variables(arena, names), data_dir);
}

//
// The path of an app's config file on a desktop platform, from its names and the process environment, failing for a mobile platform or
// when the app's names are missing.
//
pub fn desktopConfigPath(
    arena: std.mem.Allocator,
    platform: platform_lib.Platform,
    names: ?platform_lib.AppNames,
) ![]const u8 {
    if (platform == .android or platform == .ios) {
        return error.NotADesktopPlatform;
    }
    const app_names = names orelse {
        return errors.throwError("Cannot find where the config file goes: the core was built for no app, so it has no name.", .{});
    };
    std.debug.assert(app_names.name.len > 0);
    std.debug.assert(app_names.title.len > 0);
    return config_path.path(arena, platform, app_names, try variables(arena, app_names), "");
}

//
// The path of the config file for a program with no native app, from the names its build gave the core.
//
pub fn desktopAppConfigPath(arena: std.mem.Allocator) ![]const u8 {
    return desktopConfigPath(arena, platform_lib.currentPlatform(), buildNames());
}

//
// The names the build gave the core, or null when it was built for no app.
//
fn buildNames() ?platform_lib.AppNames {
    if (build_options.app_name == null or build_options.app_title == null) {
        return null;
    }
    return .{
        .name = build_options.app_name.?,
        .title = build_options.app_title.?,
    };
}

//
// The variables the config file's rule reads, from the process environment or the environment the native app gave the core.
//
fn variables(arena: std.mem.Allocator, names: platform_lib.AppNames) !config_path.Variables {
    return .{
        .config_dir_override = try environment_variable.get(arena, try variableName(arena, names)),
        .home = try environment_variable.get(arena, "HOME"),
        .cf_fixed_user_home = try environment_variable.get(arena, "CFFIXED_USER_HOME"),
        .xdg_config_home = try environment_variable.get(arena, "XDG_CONFIG_HOME"),
        .app_data = try environment_variable.get(arena, "APPDATA"),
    };
}
