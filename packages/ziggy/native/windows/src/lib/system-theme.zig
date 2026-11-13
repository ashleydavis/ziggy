//
// The system's theme, read from the registry, and the web view's colour scheme.
//

const std = @import("std");

//
// The system's theme, matching ZIGGY_THEME_LIGHT and ZIGGY_THEME_DARK in ziggy.h.
//
pub const SystemTheme = enum(c_int) {
    light = 0,
    dark = 1,
};

//
// The theme AppsUseLightTheme names: 0 is dark, missing or anything else light.
//
pub fn fromAppsUseLightTheme(value: ?u32) SystemTheme {
    if (value) |given| {
        if (given == 0) {
            return .dark;
        }
    }
    return .light;
}

//
// The web view's colour scheme: 0 is COREWEBVIEW2_PREFERRED_COLOR_SCHEME_AUTO, 1 is _LIGHT and 2 is _DARK.
//
pub fn preferredColorScheme(setting: []const u8, theme: []const u8) c_int {
    if (std.mem.eql(u8, setting, "system")) {
        return 0;
    }
    if (std.mem.eql(u8, theme, "dark")) {
        return 2;
    }
    return 1;
}
