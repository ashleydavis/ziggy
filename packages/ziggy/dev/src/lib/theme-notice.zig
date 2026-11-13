//
// The line the dev host prints when the core sends a theme call.
//

const std = @import("std");

//
// The line for a setting, or null for system, because the browser's own colour scheme is the page's prefers-color-scheme.
//
pub fn themeNotice(allocator: std.mem.Allocator, setting: []const u8) !?[]u8 {
    if (std.mem.eql(u8, setting, "system")) {
        return null;
    }
    return try std.fmt.allocPrint(allocator, "ziggy dev host: the browser's own colour scheme is the page's prefers-color-scheme; the theme setting {s} reaches the page only through getConfig and config-changed", .{setting});
}
