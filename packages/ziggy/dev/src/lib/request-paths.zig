//
// What the dev host makes of a request: the name a dropped file is saved under, and the parameters of a query.
//

const std = @import("std");

//
// The name a dropped file is saved under: the last part of the name the browser gave, or error.BadFileName when that is empty or
// is "." or "..". A browser gives a bare name, so anything before a slash is dropped rather than trusted.
//
pub fn droppedFileName(name: []const u8) error{BadFileName}![]const u8 {
    const last_separator = std.mem.lastIndexOfAny(u8, name, "/\\");
    const base = if (last_separator) |index| name[index + 1 ..] else name;
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        return error.BadFileName;
    }
    return base;
}

//
// The value of one parameter of a request target's query, still percent-encoded, or null when the query has none.
//
pub fn queryParameter(target: []const u8, name: []const u8) ?[]const u8 {
    const question = std.mem.indexOfScalar(u8, target, '?') orelse {
        return null;
    };
    var pairs = std.mem.splitScalar(u8, target[question + 1 ..], '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (std.mem.eql(u8, pair[0..equals], name)) {
            return if (equals < pair.len) pair[equals + 1 ..] else "";
        }
    }
    return null;
}

//
// Decodes percent-encoding into the buffer given and returns the decoded text, or error.BadEncoding when a % is not followed by
// two hex digits, or error.NoSpaceLeft when the buffer is too small.
//
pub fn percentDecode(buffer: []u8, encoded: []const u8) error{ BadEncoding, NoSpaceLeft }![]const u8 {
    var length: usize = 0;
    var index: usize = 0;
    while (index < encoded.len) {
        if (length >= buffer.len) {
            return error.NoSpaceLeft;
        }
        if (encoded[index] == '%') {
            if (index + 3 > encoded.len) {
                return error.BadEncoding;
            }
            buffer[length] = std.fmt.parseInt(u8, encoded[index + 1 .. index + 3], 16) catch {
                return error.BadEncoding;
            };
            index += 3;
        }
        else {
            buffer[length] = encoded[index];
            index += 1;
        }
        length += 1;
    }
    return buffer[0..length];
}
