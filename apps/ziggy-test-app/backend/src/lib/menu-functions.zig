//
// The Zig functions the test app's menu items run (its `.zig` items).
//

const std = @import("std");
const ziggy = @import("ziggy");

//
// Send Event From Zig: sends the UI the app event {"type": "menu-zig-event"}, which shows that a `.zig` item ran in the core and that
// what it sends reaches the UI.
//
pub fn sendZigEvent(core: *ziggy.core.Core, arena: std.mem.Allocator) !void {
    try core.sendEvent(arena, "{\"type\":\"menu-zig-event\"}");
}
