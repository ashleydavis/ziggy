//
// The platform's system message: get-platform, which reports what the app runs on.
//

const builtin = @import("builtin");

//
// The message response to get-platform.
//
pub const PlatformResponse = struct {
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
pub fn getPlatform() PlatformResponse {
    return .{
        .platformKind = switch (builtin.os.tag) {
            .ios => "mobile",
            else => if (builtin.abi.isAndroid()) "mobile" else "desktop",
        },
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
    };
}
