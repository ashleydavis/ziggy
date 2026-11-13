const std = @import("std");
const web_view_theme = @import("../lib/web-view-theme.zig");

test "a theme name loses its -dark or -Dark suffix" {
    try std.testing.expectEqualStrings("Yaru-purple", web_view_theme.lightThemeName("Yaru-purple-dark").?);
    try std.testing.expectEqualStrings("Yaru-purple", web_view_theme.lightThemeName("Yaru-purple-Dark").?);
}

test "a name with no suffix gives nothing" {
    try std.testing.expect(web_view_theme.lightThemeName("Adwaita") == null);
    try std.testing.expect(web_view_theme.lightThemeName("dark") == null);
    try std.testing.expect(web_view_theme.lightThemeName("Dark") == null);
}

test "a name that is only the suffix gives nothing" {
    try std.testing.expect(web_view_theme.lightThemeName("-dark") == null);
    try std.testing.expect(web_view_theme.lightThemeName("-Dark") == null);
}

test "GTK_THEME names a dark theme by its suffix" {
    try std.testing.expect(web_view_theme.forcesDark("Adwaita-dark"));
    try std.testing.expect(web_view_theme.forcesDark("Adwaita-Dark"));
    try std.testing.expect(web_view_theme.forcesDark("Adwaita:dark"));
    try std.testing.expect(!web_view_theme.forcesDark("Adwaita"));
    try std.testing.expect(!web_view_theme.forcesDark("Adwaita-light"));
}
