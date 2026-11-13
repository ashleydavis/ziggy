const std = @import("std");
const system_theme = @import("../lib/system-theme.zig");

test "AppsUseLightTheme 0 is dark and everything else light" {
    try std.testing.expectEqual(system_theme.SystemTheme.dark, system_theme.fromAppsUseLightTheme(0));
    try std.testing.expectEqual(system_theme.SystemTheme.light, system_theme.fromAppsUseLightTheme(1));
    try std.testing.expectEqual(system_theme.SystemTheme.light, system_theme.fromAppsUseLightTheme(null));
}

test "the colour scheme follows the setting and the theme" {
    try std.testing.expectEqual(@as(c_int, 0), system_theme.preferredColorScheme("system", "dark"));
    try std.testing.expectEqual(@as(c_int, 2), system_theme.preferredColorScheme("dark", "dark"));
    try std.testing.expectEqual(@as(c_int, 1), system_theme.preferredColorScheme("light", "light"));
}
