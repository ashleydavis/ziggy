const std = @import("std");
const request_paths = @import("../lib/request-paths.zig");

test "a dropped file is saved under the last part of its name" {
    try std.testing.expectEqualStrings("photo.jpg", try request_paths.droppedFileName("photo.jpg"));
    try std.testing.expectEqualStrings("photo.jpg", try request_paths.droppedFileName("../../photo.jpg"));
    try std.testing.expectEqualStrings("photo.jpg", try request_paths.droppedFileName("C:\\Users\\me\\photo.jpg"));
}

test "a dropped file with no usable name is refused" {
    try std.testing.expectError(error.BadFileName, request_paths.droppedFileName(""));
    try std.testing.expectError(error.BadFileName, request_paths.droppedFileName(".."));
    try std.testing.expectError(error.BadFileName, request_paths.droppedFileName("folder/"));
}

test "a query parameter is found by name, still encoded, and a missing one is null" {
    try std.testing.expectEqualStrings("a%20b.txt", request_paths.queryParameter("/__ziggy/dropped-file?x=1&name=a%20b.txt", "name").?);
    try std.testing.expectEqualStrings("", request_paths.queryParameter("/x?name", "name").?);
    try std.testing.expect(request_paths.queryParameter("/x?other=1", "name") == null);
    try std.testing.expect(request_paths.queryParameter("/x", "name") == null);
}

test "percent-encoding is decoded, and a broken escape is an error" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a b/é.txt", try request_paths.percentDecode(&buffer, "a%20b%2F%C3%A9.txt"));
    try std.testing.expectError(error.BadEncoding, request_paths.percentDecode(&buffer, "a%2"));
    try std.testing.expectError(error.BadEncoding, request_paths.percentDecode(&buffer, "a%zz"));
    var small: [2]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, request_paths.percentDecode(&small, "abc"));
}
