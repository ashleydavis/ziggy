const std = @import("std");
const theme_notice = @import("../lib/theme-notice.zig");

test "system gives no line" {
    try std.testing.expect((try theme_notice.themeNotice(std.testing.allocator, "system")) == null);
}

test "light and dark give the line" {
    const light = (try theme_notice.themeNotice(std.testing.allocator, "light")).?;
    defer std.testing.allocator.free(light);
    try std.testing.expectEqualStrings("ziggy dev host: the browser's own colour scheme is the page's prefers-color-scheme; the theme setting light reaches the page only through getConfig and config-changed", light);
    const dark = (try theme_notice.themeNotice(std.testing.allocator, "dark")).?;
    defer std.testing.allocator.free(dark);
    try std.testing.expectEqualStrings("ziggy dev host: the browser's own colour scheme is the page's prefers-color-scheme; the theme setting dark reaches the page only through getConfig and config-changed", dark);
}

test "running out of memory fails cleanly" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, noticeAndFree, .{});
}

//
// Makes the line and frees it, for the allocation failure test.
//
fn noticeAndFree(allocator: std.mem.Allocator) !void {
    const line = (try theme_notice.themeNotice(allocator, "dark")) orelse return error.NoLine;
    allocator.free(line);
}
