//
// The platforms Ziggy runs on and the path rules they share.
//

const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils");
const errors = utils.errors;

//
// The platforms Ziggy runs on, each with its own rule for where its file is kept.
//
pub const Platform = enum {
    linux,
    macos,
    windows,
    android,
    ios,
};

//
// The platform this build runs on.
//
pub fn currentPlatform() Platform {
    if (builtin.abi.isAndroid()) {
        return .android;
    }
    return switch (builtin.os.tag) {
        .linux => .linux,
        .macos => .macos,
        .windows => .windows,
        .ios => .ios,
        else => @panic("Ziggy has no config or state file location for this platform"),
    };
}

//
// The names an app gives its files: its name, and its name as people read it.
//
pub const AppNames = struct {
    // The app's name, such as "ziggy-template".
    name: []const u8,
    // The app's name as people read it, such as "Ziggy template".
    title: []const u8,
};

//
// The environment variable a file's directory override is named by, such as MY_APP_CONFIG_DIR.
//
pub fn variableName(arena: std.mem.Allocator, names: AppNames, comptime suffix: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (names.name) |character| {
        try result.append(arena, if (std.ascii.isAlphanumeric(character)) std.ascii.toUpper(character) else '_');
    }
    try result.appendSlice(arena, suffix);
    return result.items;
}

//
// The environment variable an app name's file directory override is named by, for a caller that has only the name.
//
pub fn appVariableName(arena: std.mem.Allocator, app_name: []const u8, comptime suffix: []const u8) ![]const u8 {
    return variableName(arena, .{ .name = app_name, .title = app_name }, suffix);
}

//
// A value when it is present and not empty.
//
pub fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    if (text.len == 0) {
        return null;
    }
    return text;
}

//
// The separator a platform's paths use.
//
pub fn separator(platform: Platform) []const u8 {
    return if (platform == .windows) "\\" else "/";
}

//
// Joins path parts with a separator of the test's choosing, so a Windows path can be worked out on any machine.
//
pub fn join(arena: std.mem.Allocator, sep: []const u8, parts: []const []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (parts, 0..) |part, index| {
        std.debug.assert(part.len > 0);
        if (index > 0) {
            try result.appendSlice(arena, sep);
        }
        try result.appendSlice(arena, part);
    }
    return result.items;
}

//
// The home directory a desktop platform's rule reads, failing with a message naming the missing variable and the file.
//
pub fn homeDirectory(platform: Platform, home: ?[]const u8, cf_fixed_user_home: ?[]const u8, comptime file_name: []const u8) ![]const u8 {
    if (platform == .macos) {
        if (nonEmpty(cf_fixed_user_home)) |fixed_home| {
            return fixed_home;
        }
        if (nonEmpty(home)) |found_home| {
            return found_home;
        }
        return errors.throwError("Cannot find where the {s} file goes: neither CFFIXED_USER_HOME nor HOME is set.", .{file_name});
    }
    if (nonEmpty(home)) |found_home| {
        return found_home;
    }
    return errors.throwError("Cannot find where the {s} file goes: HOME is not set.", .{file_name});
}
