//
// Tests of the core's calls to the native app: the theme call's text and the fields it needs.
//

const std = @import("std");
const ziggy = @import("ziggy");

const native_message = ziggy.native_message;

test "a theme call encodes to the setting, the theme and the background" {
    const text = try native_message.encode(std.testing.allocator, .{
        .theme = .{
            .setting = "system",
            .theme = "dark",
            .background = "#000000",
        },
    }, null);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"type\":\"theme\",\"setting\":\"system\",\"theme\":\"dark\",\"background\":\"#000000\"}", text);
}

test "a theme call parses back to the same three fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const call = try native_message.parse(arena_state.allocator(), "{\"type\":\"theme\",\"setting\":\"light\",\"theme\":\"light\",\"background\":\"#ffffff\"}");
    try std.testing.expectEqual(native_message.Call.theme, std.meta.activeTag(call));
    try std.testing.expectEqualStrings("light", call.theme.setting);
    try std.testing.expectEqualStrings("light", call.theme.theme);
    try std.testing.expectEqualStrings("#ffffff", call.theme.background);
}

test "a theme call missing any field is InvalidCall" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.InvalidCall, native_message.parse(arena, "{\"type\":\"theme\",\"setting\":\"light\",\"theme\":\"light\"}"));
    try std.testing.expectError(error.InvalidCall, native_message.parse(arena, "{\"type\":\"theme\",\"setting\":\"light\",\"background\":\"#ffffff\"}"));
    try std.testing.expectError(error.InvalidCall, native_message.parse(arena, "{\"type\":\"theme\",\"theme\":\"light\",\"background\":\"#ffffff\"}"));
}
