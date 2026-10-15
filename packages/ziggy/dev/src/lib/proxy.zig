//
// What the dev host makes of the requests it forwards to the app's own dev server, and of the responses that come back. The dev
// host stands in front of the dev server: the browser opens the dev host, which serves /__ziggy itself and forwards everything
// else. It requests each response from the dev server whole and uncompressed, on a connection that closes after it, so a response ends where
// the connection does, and it puts Ziggy's scripts into a page on the way back.
//

const std = @import("std");

// The scripts the dev host puts at the start of a page's head, in order: its own dev script first, because the inject script
// looks for the handler it sets up, and then the inject script that creates window.ziggy. Both run before any script of the UI.
pub const dev_scripts = "<script src=\"/__ziggy/dev.js\"></script><script src=\"/__ziggy/inject.js\"></script>";

//
// The request to send the dev server for a request the browser sent: the same request line and headers, except that it sets accept-encoding: identity for an
// uncompressed response on a connection that closes after it, and gives the body's length when it has one. The head given is the
// browser's, as received, ending in a blank line. The caller owns the result.
//
pub fn upstreamRequestHead(allocator: std.mem.Allocator, head: []const u8, body_length: ?usize) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = lines.next() orelse {
        return error.EmptyHead;
    };
    try result.appendSlice(allocator, request_line);
    try result.appendSlice(allocator, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) {
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            return error.BadHeader;
        };
        const name = std.mem.trim(u8, line[0..colon], " ");
        if (isReplacedRequestHeader(name)) {
            continue;
        }
        try result.appendSlice(allocator, line);
        try result.appendSlice(allocator, "\r\n");
    }
    try result.appendSlice(allocator, "connection: close\r\naccept-encoding: identity\r\n");
    if (body_length) |length| {
        try result.print(allocator, "content-length: {d}\r\n", .{length});
    }
    try result.appendSlice(allocator, "\r\n");
    return result.toOwnedSlice(allocator);
}

//
// Whether a header of the browser's request is left out of the forwarded one, because the dev host sets it itself.
//
fn isReplacedRequestHeader(name: []const u8) bool {
    const replaced = [_][]const u8{ "connection", "keep-alive", "proxy-connection", "accept-encoding", "content-length", "transfer-encoding" };
    for (replaced) |replaced_name| {
        if (std.ascii.eqlIgnoreCase(name, replaced_name)) {
            return true;
        }
    }
    return false;
}

//
// What the head of the dev server's response says about its body.
//
pub const ResponseHead = struct {
    // Whether the response is an HTML page, which gets Ziggy's scripts.
    html: bool,
    // The body's length, when the head gives one.
    content_length: ?usize,
    // Whether the body comes in chunks.
    chunked: bool,
};

//
// Reads what matters about the body from the head of a response, as received, ending in a blank line.
//
pub fn parseResponseHead(head: []const u8) !ResponseHead {
    var result = ResponseHead{
        .html = false,
        .content_length = null,
        .chunked = false,
    };
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next() orelse {
        return error.EmptyHead;
    };
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            continue;
        };
        const name = std.mem.trim(u8, line[0..colon], " ");
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            result.html = std.ascii.startsWithIgnoreCase(value, "text/html");
        }
        else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            result.content_length = std.fmt.parseInt(usize, value, 10) catch {
                return error.BadContentLength;
            };
        }
        else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            result.chunked = std.ascii.indexOfIgnoreCase(value, "chunked") != null;
        }
    }
    return result;
}

//
// The head to send the browser for a page whose body has changed length: the dev server's status line and headers, without its
// length, its chunking or its connection header, with the new length and a connection that closes after it. The caller owns it.
//
pub fn pageResponseHead(allocator: std.mem.Allocator, head: []const u8, body_length: usize) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse {
        return error.EmptyHead;
    };
    try result.appendSlice(allocator, status_line);
    try result.appendSlice(allocator, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) {
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            continue;
        };
        const name = std.mem.trim(u8, line[0..colon], " ");
        if (std.ascii.eqlIgnoreCase(name, "content-length") or std.ascii.eqlIgnoreCase(name, "transfer-encoding") or std.ascii.eqlIgnoreCase(name, "connection")) {
            continue;
        }
        try result.appendSlice(allocator, line);
        try result.appendSlice(allocator, "\r\n");
    }
    try result.print(allocator, "content-length: {d}\r\nconnection: close\r\n\r\n", .{body_length});
    return result.toOwnedSlice(allocator);
}

//
// A page with Ziggy's scripts at the start of its head, or at the start of the document when it has no head. The caller owns it.
//
pub fn withDevScripts(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    const insert_at = afterOpeningTag(html, "<head") orelse afterOpeningTag(html, "<html") orelse 0;
    return std.mem.concat(allocator, u8, &.{ html[0..insert_at], dev_scripts, html[insert_at..] });
}

//
// The position just after the opening tag that starts with the text given, ignoring case, or null when the document has none.
//
fn afterOpeningTag(html: []const u8, tag_start: []const u8) ?usize {
    var search_from: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(html, search_from, tag_start)) |start| {
        const next = start + tag_start.len;
        // "<header" also starts with "<head", so the tag's name has to end there.
        if (next < html.len and (html[next] == '>' or std.ascii.isWhitespace(html[next]))) {
            const close = std.mem.indexOfScalarPos(u8, html, next, '>') orelse {
                return null;
            };
            return close + 1;
        }
        search_from = next;
    }
    return null;
}

//
// Reads a chunked body to its end and returns it joined. The caller owns it.
//
pub fn readChunkedBody(allocator: std.mem.Allocator, reader: *std.Io.Reader, limit: usize) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    while (true) {
        const size_line = std.mem.trimEnd(u8, try reader.takeDelimiterInclusive('\n'), "\r\n");
        const size_text = size_line[0 .. std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len];
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, size_text, " "), 16) catch {
            return error.BadChunkSize;
        };
        if (size == 0) {
            // Trailer lines, if any, end with a blank line.
            while (true) {
                const trailer = std.mem.trimEnd(u8, try reader.takeDelimiterInclusive('\n'), "\r\n");
                if (trailer.len == 0) {
                    return body.toOwnedSlice(allocator);
                }
            }
        }
        if (body.items.len + size > limit) {
            return error.BodyTooLarge;
        }
        try reader.readSliceAll(try body.addManyAsSlice(allocator, size));
        const end = try reader.takeArray(2);
        if (!std.mem.eql(u8, end, "\r\n")) {
            return error.BadChunkEnd;
        }
    }
}
