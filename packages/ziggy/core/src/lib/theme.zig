//
// The theme setting: light, dark or system, the system's own theme, and the window background colours each theme uses.
//

const std = @import("std");

//
// The theme setting: what the user chose.
//
pub const Setting = enum {
    light,
    dark,
    system,
};

//
// A theme the app draws in.
//
pub const Theme = enum {
    light,
    dark,
};

//
// Parses a setting from the config file or an argument. Fails with UnknownTheme for any other text.
//
pub fn parseSetting(text: []const u8) !Setting {
    if (std.mem.eql(u8, text, "light")) {
        return .light;
    }
    if (std.mem.eql(u8, text, "dark")) {
        return .dark;
    }
    if (std.mem.eql(u8, text, "system")) {
        return .system;
    }
    return error.UnknownTheme;
}

//
// The theme a setting resolves to, given the system's theme.
//
pub fn resolve(setting: Setting, system: Theme) Theme {
    return switch (setting) {
        .light => .light,
        .dark => .dark,
        .system => system,
    };
}

//
// The command line with --theme taken out.
//
pub const TakenTheme = struct {
    // The setting after --theme, or null when the command line has none.
    setting: ?Setting,
    // The command line without --theme and its value, allocated with the allocator given to take. The strings are the command
    // line's own.
    remaining: []const []const u8,
};

//
// Takes --theme and the setting after it out of the argument list, which has no program name. Fails with ThemeValueMissing when
// --theme is the last argument, ThemeGivenTwice when it is given more than once and UnknownTheme for a value that is not a setting.
// The caller frees `remaining` with the allocator.
//
pub fn takeArgument(allocator: std.mem.Allocator, arguments: []const []const u8) !TakenTheme {
    var setting: ?Setting = null;
    var remaining: std.ArrayList([]const u8) = try .initCapacity(allocator, arguments.len);
    errdefer remaining.deinit(allocator);
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (!std.mem.eql(u8, argument, "--theme")) {
            remaining.appendAssumeCapacity(argument);
            continue;
        }
        if (index + 1 >= arguments.len) {
            return error.ThemeValueMissing;
        }
        if (setting != null) {
            return error.ThemeGivenTwice;
        }
        setting = try parseSetting(arguments[index + 1]);
        index += 1;
    }
    std.debug.assert(remaining.items.len <= arguments.len);
    if (setting != null) {
        std.debug.assert(remaining.items.len + 2 == arguments.len);
    }
    return .{
        .setting = setting,
        .remaining = try remaining.toOwnedSlice(allocator),
    };
}

//
// The background colours an app declares for its window, one for each theme, so the window matches the page before the page draws.
//
pub const Backgrounds = struct {
    // The colour the window is painted in the light theme.
    light: u24 = 0xffffff,
    // The colour the window is painted in the dark theme.
    dark: u24 = 0x000000,
};

//
// The run's theme: the setting, and the system's own theme.
//
pub const ThemeState = struct {
    // What the user chose, or what an argument gave for this run.
    setting: Setting,
    // The theme the system is in.
    system: Theme,

    //
    // The theme the setting resolves to.
    //
    pub fn theme(self: ThemeState) Theme {
        return resolve(self.setting, self.system);
    }

    //
    // Changes the setting, returning whether the setting or the theme changed.
    //
    pub fn applySetting(self: *ThemeState, setting: Setting) bool {
        const old_setting = self.setting;
        const old_theme = self.theme();
        self.setting = setting;
        return old_setting != setting or old_theme != self.theme();
    }

    //
    // Changes the system's theme, returning whether the theme changed.
    //
    pub fn applySystem(self: *ThemeState, system: Theme) bool {
        const old_theme = self.theme();
        self.system = system;
        return old_theme != self.theme();
    }
};

//
// The theme state as JSON: {"setting":"system","theme":"dark"}.
//
pub fn stateJson(arena: std.mem.Allocator, state: ThemeState) ![]u8 {
    return std.json.Stringify.valueAlloc(arena, .{
        .setting = @tagName(state.setting),
        .theme = @tagName(state.theme()),
    }, .{ .emit_null_optional_fields = false });
}

//
// A background colour as #rrggbb, in lower case.
//
pub fn backgroundText(allocator: std.mem.Allocator, backgrounds: Backgrounds, theme: Theme) ![]u8 {
    const colour = switch (theme) {
        .light => backgrounds.light,
        .dark => backgrounds.dark,
    };
    return std.fmt.allocPrint(allocator, "#{x:0>6}", .{colour});
}
