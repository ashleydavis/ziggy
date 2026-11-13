const std = @import("std");
const system_theme = @import("../lib/system-theme.zig");

test "the portal's 1 is dark and everything else is light" {
    try std.testing.expectEqual(system_theme.SystemTheme.dark, system_theme.fromColorScheme(1));
    try std.testing.expectEqual(system_theme.SystemTheme.light, system_theme.fromColorScheme(0));
    try std.testing.expectEqual(system_theme.SystemTheme.light, system_theme.fromColorScheme(2));
}
