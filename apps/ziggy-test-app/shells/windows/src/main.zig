//
// The Ziggy test app's Windows shell: what is the test app's own (its name, its window and its UI) on top of Ziggy's shell.
// The UI is embedded in the executable by build.zig.
//

const std = @import("std");
const shell = @import("ziggy-native-windows");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    return try shell.run(.{
        .app_id = "dev.ziggy.testapp",
        .title = "Ziggy test app",
        .default_width = 900,
        .default_height = 800,
        .icon_resource = null,
    }, args);
}
