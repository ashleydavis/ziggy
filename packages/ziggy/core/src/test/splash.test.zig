//
// The splash page generator: the window orientation and the HTML document it builds from an app's background and images.
//

const std = @import("std");
const ziggy = @import("ziggy");

test "a window taller than it is wide is portrait" {
    try std.testing.expectEqual(ziggy.splash.Orientation.portrait, ziggy.splash.orientation(800, 1200));
}

test "a window wider than it is tall is landscape" {
    try std.testing.expectEqual(ziggy.splash.Orientation.landscape, ziggy.splash.orientation(1200, 800));
}

test "a square window is landscape" {
    try std.testing.expectEqual(ziggy.splash.Orientation.landscape, ziggy.splash.orientation(1000, 1000));
}

test "the page has the background, both image paths and the landscape media query" {
    const page = try ziggy.splash.html(std.testing.allocator, "#1B1035", "ziggy-splash-portrait.png", "ziggy-splash-landscape.png");
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "#1B1035") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "ziggy-splash-portrait.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "ziggy-splash-landscape.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "(orientation: landscape)") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<picture>") != null);
}

test "the page escapes every input for HTML" {
    const background = "#fff\" onload=\"x&<>";
    const portrait = "portrait&<>\".png";
    const landscape = "landscape&<>\".png";
    const page = try ziggy.splash.html(std.testing.allocator, background, portrait, landscape);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, background) == null);
    try std.testing.expect(std.mem.indexOf(u8, page, portrait) == null);
    try std.testing.expect(std.mem.indexOf(u8, page, landscape) == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "#fff&quot; onload=&quot;x&amp;&lt;&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "portrait&amp;&lt;&gt;&quot;.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "landscape&amp;&lt;&gt;&quot;.png") != null);
}
