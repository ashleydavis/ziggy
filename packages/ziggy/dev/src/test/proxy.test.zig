const std = @import("std");
const proxy = @import("../lib/proxy.zig");

test "a forwarded request keeps the browser's request line and headers, and asks for a whole uncompressed answer" {
    const head = "GET /src/main.ts?t=1 HTTP/1.1\r\nHost: 127.0.0.1:4000\r\nAccept: */*\r\nConnection: keep-alive\r\nAccept-Encoding: gzip, br\r\nUser-Agent: test\r\n\r\n";
    const result = try proxy.upstreamRequestHead(std.testing.allocator, head, null);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("GET /src/main.ts?t=1 HTTP/1.1\r\nHost: 127.0.0.1:4000\r\nAccept: */*\r\nUser-Agent: test\r\nconnection: close\r\naccept-encoding: identity\r\n\r\n", result);
}

test "a forwarded request with a body gives the body's length in place of the browser's" {
    const head = "POST /api HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    const result = try proxy.upstreamRequestHead(std.testing.allocator, head, 12);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("POST /api HTTP/1.1\r\nHost: x\r\nconnection: close\r\naccept-encoding: identity\r\ncontent-length: 12\r\n\r\n", result);
}

test "an answer's head says whether it is a page, how long its body is and whether it comes in chunks" {
    const page = try proxy.parseResponseHead("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 42\r\n\r\n");
    try std.testing.expect(page.html);
    try std.testing.expectEqual(@as(?usize, 42), page.content_length);
    try std.testing.expect(!page.chunked);
    const script = try proxy.parseResponseHead("HTTP/1.1 200 OK\r\ncontent-type: text/javascript\r\ntransfer-encoding: chunked\r\n\r\n");
    try std.testing.expect(!script.html);
    try std.testing.expect(script.content_length == null);
    try std.testing.expect(script.chunked);
    try std.testing.expectError(error.BadContentLength, proxy.parseResponseHead("HTTP/1.1 200 OK\r\nContent-Length: lots\r\n\r\n"));
}

test "a page's new head has the new length and a closing connection, and none of the old length, chunking or connection" {
    const head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\nCache-Control: no-cache\r\n\r\n";
    const result = try proxy.pageResponseHead(std.testing.allocator, head, 99);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-cache\r\ncontent-length: 99\r\nconnection: close\r\n\r\n", result);
}

test "Ziggy's scripts go at the start of the head, before the page's own scripts" {
    const html = "<!doctype html><html><head><title>x</title><script src=\"app.js\"></script></head></html>";
    const result = try proxy.withDevScripts(std.testing.allocator, html);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<!doctype html><html><head>" ++ proxy.dev_scripts ++ "<title>x</title><script src=\"app.js\"></script></head></html>", result);
}

test "a head tag with attributes or in capitals is found, and a header element is not taken for it" {
    const html = "<HTML><header></header><HEAD lang=\"en\"><title>x</title></HEAD>";
    const result = try proxy.withDevScripts(std.testing.allocator, html);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<HTML><header></header><HEAD lang=\"en\">" ++ proxy.dev_scripts ++ "<title>x</title></HEAD>", result);
}

test "a page without a head gets the scripts after its html tag, and one without either at its start" {
    const no_head = try proxy.withDevScripts(std.testing.allocator, "<html><body></body></html>");
    defer std.testing.allocator.free(no_head);
    try std.testing.expectEqualStrings("<html>" ++ proxy.dev_scripts ++ "<body></body></html>", no_head);
    const bare = try proxy.withDevScripts(std.testing.allocator, "<p>hi</p>");
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings(proxy.dev_scripts ++ "<p>hi</p>", bare);
}

test "a chunked body is joined, with chunk extensions and trailers skipped" {
    var reader: std.Io.Reader = .fixed("5;name=x\r\nhello\r\n7\r\n, world\r\n0\r\nX-Trailer: 1\r\n\r\n");
    const body = try proxy.readChunkedBody(std.testing.allocator, &reader, 1024);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("hello, world", body);
}

test "a chunked body longer than the limit, or with a broken chunk, is refused" {
    var long: std.Io.Reader = .fixed("a\r\n0123456789\r\n0\r\n\r\n");
    try std.testing.expectError(error.BodyTooLarge, proxy.readChunkedBody(std.testing.allocator, &long, 5));
    var bad_size: std.Io.Reader = .fixed("zz\r\n");
    try std.testing.expectError(error.BadChunkSize, proxy.readChunkedBody(std.testing.allocator, &bad_size, 5));
    var bad_end: std.Io.Reader = .fixed("2\r\nabXX0\r\n\r\n");
    try std.testing.expectError(error.BadChunkEnd, proxy.readChunkedBody(std.testing.allocator, &bad_end, 5));
}
