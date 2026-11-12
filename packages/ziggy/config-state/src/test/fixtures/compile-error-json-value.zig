//
// Proves that a type no file can hold is a compile error naming the type, here std.json.Value.
//

const std = @import("std");
const config_state = @import("config_state");

test "the typed API rejects std.json.Value" {
    try config_state.config.get(std.json.Value, std.testing.allocator, std.testing.io, "config.toml", "key");
}
