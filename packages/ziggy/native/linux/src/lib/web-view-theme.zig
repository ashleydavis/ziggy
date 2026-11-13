//
// How the GTK theme names the theme WebKitGTK reports to the page.
//

const std = @import("std");

//
// The GTK theme name without a final -dark or -Dark, or null when it has neither.
//
pub fn lightThemeName(name: []const u8) ?[]const u8 {
    const without_suffix = if (std.mem.endsWith(u8, name, "-dark"))
        name[0 .. name.len - "-dark".len]
    else if (std.mem.endsWith(u8, name, "-Dark"))
        name[0 .. name.len - "-Dark".len]
    else
        return null;
    return if (without_suffix.len == 0) null else without_suffix;
}

//
// Whether GTK_THEME names a dark theme, as WebKitGTK reads it: a value ending in -dark, -Dark or :dark.
//
pub fn forcesDark(gtk_theme_env: []const u8) bool {
    return std.mem.endsWith(u8, gtk_theme_env, "-dark") or std.mem.endsWith(u8, gtk_theme_env, "-Dark") or std.mem.endsWith(u8, gtk_theme_env, ":dark");
}
