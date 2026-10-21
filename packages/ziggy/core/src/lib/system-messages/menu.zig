//
// The menu's system message: menu-action, which a native app sends when a menu item it does not run itself is chosen.
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
    // The action of the menu item that was chosen: the name of a `.zig` or `.ui` item of the app's menu.
    action: []const u8,
};

//
// The message response to menu-action, an empty object.
//
const DoneResponse = struct {};

//
// A menu item was chosen, by the user or by a keyboard shortcut. The native app passes its action on. The core runs the item: it
// calls a `.zig` item's function, whose error is this message's error. It sends a `.ui` item to the UI as the app event
// {"type": "menu", "item": "<name>"}. A name the app's menu does not have fails with UnknownMenuItem. So does a standard action,
// which the native apps do themselves and never post.
//
fn menuActionHandler(core: *Core, arena: std.mem.Allocator, request: MenuActionRequest) !DoneResponse {
    const target = core.menu_targets.get(request.action) orelse {
        return error.UnknownMenuItem;
    };
    switch (target) {
        .zig => |function| {
            try function(core, arena);
        },
        .ui => {
            try core.sendEvent(arena, try json.stringify(arena, .{
                .type = "menu",
                .item = request.action,
            }));
        },
    }
    return .{};
}
