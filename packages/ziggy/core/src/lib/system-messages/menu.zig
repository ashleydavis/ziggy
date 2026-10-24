//
// The menu's system message: menu-action, which a native app sends when a menu item it does not run itself is chosen.
//

const std = @import("std");
const json = @import("../json.zig");
const menu_lib = @import("../menu.zig");
const services_lib = @import("../services.zig");
const timers_lib = @import("../timers.zig");

//
// The data of menu-action.
//
pub const MenuActionRequest = struct {
    // The action of the menu item that was chosen: the name of a `.zig` or `.ui` item of the app's menu.
    action: []const u8,
};

//
// The message response to menu-action, an empty object.
//
pub const DoneResponse = struct {};

//
// A menu item was chosen, by the user or by a keyboard shortcut. The native app passes its action on. The main thread runs the item:
// it calls a `.zig` item's function with the standard arguments, and its error is this message's error. It sends a `.ui` item to the
// frontend as the app event {"type": "menu", "item": "<name>"}. A name the app's menu does not have fails with UnknownMenuItem. So does
// a standard action, which the native apps do themselves and never post.
//
pub fn menuAction(menu_targets: menu_lib.MenuTargets, services: services_lib.HandlerServices, timers: timers_lib.Timers, io: std.Io, allocator: std.mem.Allocator, request: MenuActionRequest) !DoneResponse {
    const target = menu_targets.get(request.action) orelse {
        return error.UnknownMenuItem;
    };
    switch (target) {
        .zig => |function| {
            try function(services, timers, io, allocator);
        },
        .ui => {
            try services.sendEvent(io, allocator, try json.stringify(allocator, .{
                .type = "menu",
                .item = request.action,
            }));
        },
    }
    return .{};
}
