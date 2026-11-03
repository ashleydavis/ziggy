const std = @import("std");
const menu = @import("../lib/menu.zig");

test "an ampersand is doubled" {
    const escaped = try menu.escapeLabel(std.testing.allocator, "Save & Close");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("Save && Close", escaped);
}
