const std = @import("std");
const ziggy = @import("ziggy");

const writeNativeCallResult = ziggy.native_call_result.writeNativeCallResult;

test "a result that succeeded is written to the buffer and its length returned" {
    var buffer: [64]u8 = undefined;
    const length = writeNativeCallResult(true, "method", "{\"granted\":true}", &buffer, buffer.len);
    try std.testing.expectEqual(@as(isize, 16), length);
    try std.testing.expectEqualStrings("{\"granted\":true}", buffer[0..16]);
}

test "a result that failed is written as its reason and the length returned is negated" {
    var buffer: [64]u8 = undefined;
    const length = writeNativeCallResult(false, "method", "Photo access was refused.", &buffer, buffer.len);
    try std.testing.expectEqual(@as(isize, -25), length);
    try std.testing.expectEqualStrings("Photo access was refused.", buffer[0..25]);
}

test "a result that does not fit is a failure that names the method" {
    var buffer: [64]u8 = undefined;
    const length = writeNativeCallResult(true, "secureStoreGet", "0123456789012345678901234567890123456789012345678901234567890123456789", &buffer, buffer.len);
    try std.testing.expect(length < 0);
    const reason = buffer[0..@intCast(-length)];
    try std.testing.expect(std.mem.indexOf(u8, reason, "secureStoreGet") != null);
}

test "a reason longer than the buffer is cut to fit and still reported as a failure" {
    var buffer: [8]u8 = undefined;
    const length = writeNativeCallResult(false, "method", "This reason is far too long.", &buffer, buffer.len);
    try std.testing.expectEqual(@as(isize, -8), length);
    try std.testing.expectEqualStrings("This rea", buffer[0..8]);
}

test "an empty result that succeeded is length zero" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), writeNativeCallResult(true, "method", "", &buffer, buffer.len));
}
