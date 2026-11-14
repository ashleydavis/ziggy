//
// Generates the splash page an app shows while its frontend loads: the app's background colour and its portrait or
// landscape image, sized to the window.
//

const std = @import("std");

//
// Which way round a window is: landscape when it is at least as wide as it is tall, portrait otherwise.
//
pub const Orientation = enum {
    portrait,
    landscape,
};

//
// The orientation of a window of the given size.
//
pub fn orientation(width: u32, height: u32) Orientation {
    if (width >= height) {
        return .landscape;
    }
    return .portrait;
}

//
// The splash page, as a complete HTML document. The background and both image paths are escaped for HTML, so a value from
// an app.zon cannot close an attribute or add an element.
//
pub fn html(
    allocator: std.mem.Allocator,
    background: []const u8,
    portrait_path: []const u8,
    landscape_path: []const u8,
) ![]u8 {
    var page: std.ArrayList(u8) = .empty;
    errdefer page.deinit(allocator);
    try page.appendSlice(allocator, "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n<style>\nhtml, body, picture, img { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; }\nimg { display: block; object-fit: cover; object-position: center; }\nbody { background: ");
    try appendEscaped(allocator, &page, background);
    try page.appendSlice(allocator, "; }\n</style>\n</head>\n<body>\n<picture>\n<source media=\"(orientation: landscape)\" srcset=\"");
    try appendEscaped(allocator, &page, landscape_path);
    try page.appendSlice(allocator, "\">\n<img src=\"");
    try appendEscaped(allocator, &page, portrait_path);
    try page.appendSlice(allocator, "\" alt=\"\">\n</picture>\n</body>\n</html>\n");
    return page.toOwnedSlice(allocator);
}

//
// Appends text escaped for HTML, so &, <, > and " in an app.zon value cannot change the page's structure.
//
fn appendEscaped(allocator: std.mem.Allocator, page: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |character| {
        switch (character) {
            '&' => try page.appendSlice(allocator, "&amp;"),
            '<' => try page.appendSlice(allocator, "&lt;"),
            '>' => try page.appendSlice(allocator, "&gt;"),
            '"' => try page.appendSlice(allocator, "&quot;"),
            else => try page.append(allocator, character),
        }
    }
}
