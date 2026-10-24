//
// The Ziggy template's Linux native app: what is the template's own (its name, its window and its frontend) on top of the part
// Ziggy provides. The frontend is embedded in the executable by build.zig.
//

const std = @import("std");
const native_app = @import("ziggy-native-linux");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    return try native_app.run(.{
        .native_call = null,
        .app_id = "dev.ziggy.template",
        .title = "Ziggy template",
        .default_width = 900,
        .default_height = 800,
        .icon_png = null,
    }, args);
}
