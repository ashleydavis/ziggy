//
// The system message of the theme (system-theme), which a native app sends when the system's theme changes.
//

const std = @import("std");
const theme = @import("../theme.zig");

//
// The system's theme: "light" or "dark", whatever the app's setting is.
//
pub fn getSystemTheme(state: theme.ThemeState) []const u8 {
    return @tagName(state.system);
}

//
// Applies the system's theme. Returns whether the theme changed. The data is "light" or "dark".
//
pub fn systemTheme(state: *theme.ThemeState, data: []const u8) !bool {
    const system = theme.parseSetting(data) catch return error.InvalidMessageData;
    const resolved: theme.Theme = switch (system) {
        .light => .light,
        .dark => .dark,
        .system => return error.InvalidMessageData,
    };
    return state.applySystem(resolved);
}
