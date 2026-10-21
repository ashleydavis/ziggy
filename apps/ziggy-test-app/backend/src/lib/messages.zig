//
// The handlers of the test app's own messages, each registered by its message name in app.zig, with the request its data is
// parsed into and the response it returns.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");

//
// The message response to ping.
//
pub const PingResponse = struct {
    // The version of Zig the backend was built with.
    zigVersion: []const u8,
    // The operating system the backend was built for.
    os: []const u8,
    // The CPU architecture the backend was built for.
    arch: []const u8,
    // The ping's data, unchanged.
    echo: std.json.Value,
};

//
// Replies with the Zig version, the target operating system and CPU architecture, and an echo of the payload, whatever it is. It
// takes the message unparsed, the one handler of the test app that does, so the smoke tests drive that form of handler end to end.
//
pub fn pingHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, message: ziggy.core.Message) !ziggy.core.MessageResult {
    _ = core;
    const response: PingResponse = .{
        .zigVersion = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .echo = message.data,
    };
    return .{
        .response = try ziggy.json.stringify(arena, response),
    };
}

//
// The data of payload-stats.
//
pub const PayloadStatsRequest = struct {
    // The payload to measure.
    text: []const u8,
};

//
// The message response to payload-stats.
//
pub const PayloadStatsResponse = struct {
    // The length of the payload in bytes.
    length: usize,
    // The CRC-32 of the payload.
    crc32: u32,
    // The start of the payload, at most 64 bytes of it.
    text: []const u8,
};

//
// Replies with the length in bytes and the CRC-32 of the "text" field, so the UI can check a large payload
// arrived whole without the payload coming back.
//
pub fn payloadStatsHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: PayloadStatsRequest) !PayloadStatsResponse {
    _ = core;
    _ = arena;
    return .{
        .length = request.text.len,
        .crc32 = std.hash.Crc32.hash(request.text),
        .text = request.text[0..@min(request.text.len, 64)],
    };
}

//
// The data of file-roundtrip.
//
pub const FileRoundtripRequest = struct {
    // The text to write to the file and read back.
    text: []const u8,
};

//
// The message response to file-roundtrip.
//
pub const FileRoundtripResponse = struct {
    // The path of the file written.
    path: []const u8,
    // What was read back from it.
    text: []const u8,
};

//
// Writes the "text" field to a file in the app's private data directory, reads it back and replies with what it read.
// A data directory that does not exist is an error.
//
pub fn fileRoundtripHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: FileRoundtripRequest) !FileRoundtripResponse {
    const path = try std.fs.path.join(arena, &.{ core.data_dir, "ziggy-test-app-roundtrip.txt" });
    const io = core.io();
    var directory = try std.Io.Dir.cwd().openDir(io, core.data_dir, .{});
    directory.close(io);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = request.text,
    });
    return .{
        .path = path,
        .text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)),
    };
}

//
// The data of fail, which has none.
//
pub const FailRequest = struct {};

//
// Always fails, so the UI can check that an error reply reaches it.
//
pub fn failHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: FailRequest) !void {
    _ = core;
    _ = arena;
    _ = request;
    return error.ExampleFailure;
}
