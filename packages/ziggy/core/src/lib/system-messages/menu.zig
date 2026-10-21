//
// The menu's system message: menu-action, which a native app sends when a menu item the app owns is chosen.
//

const std = @import("std");
const json = @import("../json.zig");
const core_lib = @import("../core.zig");
const message_registry = @import("../message-registry.zig");

const Core = core_lib.Core;

//
// Registers the menu's system message.
//
pub fn register(registry: *message_registry.Registry) !void {
    try registry.register("menu-action", menuActionHandler);
}

//
// The data of menu-action.
//
const MenuActionRequest = struct {
    // The action of the menu item that was chosen.
    action: []const u8,
};

//
// The message response to menu-action, an empty object.
//
const DoneResponse = struct {};

//
// A menu item was chosen, by the user or by a keyboard shortcut, and the shell passes its action on. The core hands it to the
// UI as a menu-action system event, which is how the UI learns of every action the shell did not do itself.
//
fn menuActionHandler(core: *Core, arena: std.mem.Allocator, request: MenuActionRequest) !DoneResponse {
    core.deliver(try json.stringify(arena, .{
        .kind = "system",
        .name = "menu-action",
        .data = .{
            .action = request.action,
        },
    }));
    return .{};
}
