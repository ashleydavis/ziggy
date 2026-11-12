//
// Ziggy's config file and state file, where they live and how they are read and written, needing no core so a program with no
// native app can use it.
//

pub const platform = @import("lib/platform.zig");
pub const config_path = @import("lib/config-path.zig");
pub const state_path = @import("lib/state-path.zig");
pub const config = @import("lib/config.zig");
pub const state = @import("lib/state.zig");
pub const typed = @import("lib/typed.zig");
pub const key_path = @import("lib/key-path.zig");
pub const json_toml = @import("lib/json-toml.zig");
pub const atomic_file = @import("lib/atomic-file.zig");

test {
    _ = platform;
    _ = config_path;
    _ = state_path;
    _ = config;
    _ = state;
    _ = typed;
    _ = key_path;
    _ = json_toml;
    _ = atomic_file;
}
