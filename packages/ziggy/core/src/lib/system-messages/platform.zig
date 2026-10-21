//
// The platform's system message: get-platform, which says what the app runs on.
//

const std = @import("std");
const builtin = @import("builtin");
const core_lib = @import("../core.zig");
const message_registry = @import("../message-registry.zig");

const Core = core_lib.Core;

//
// Registers the platform's system message.
//
pub fn register(registry: *message_registry.Registry) !void {
    try registry.register("get-platform", getPlatformHandler);
}

//
// The data of get-platform, which has none.
//
const GetPlatformRequest = struct {};

//
// The message response to get-platform.
//
const PlatformResponse = struct {
    // "mobile" on Android and iOS, else "desktop".
    platformKind: []const u8,
    // The operating system.
    os: []const u8,
    // The CPU architecture.
    arch: []const u8,
};

//
// Handles get-platform: whether the platform is a desktop or a mobile one, and the operating system and architecture.
//
fn getPlatformHandler(core: *Core, arena: std.mem.Allocator, request: GetPlatformRequest) !PlatformResponse {
    _ = core;
    _ = arena;
    _ = request;
    return .{
        .platformKind = switch (builtin.os.tag) {
            .ios => "mobile",
            else => if (builtin.abi.isAndroid()) "mobile" else "desktop",
        },
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
    };
}
