const std = @import("std");
const ziggy = @import("ziggy");
const template = @import("ziggy-test-app-backend");

const FakeShell = ziggy.fake_shell.FakeShell;

test "the menu has the .ui items the UI handles and the zig-event item; toggle-devtools and quit are standard items" {
    for ([_][]const u8{ "start-short", "start-long", "start-many", "cancel-long", "about" }) |name| {
        const target = template.app.menu_targets.get(name) orelse return error.MenuItemMissing;
        try std.testing.expect(target == .ui);
    }
    const zig_event = template.app.menu_targets.get("zig-event") orelse return error.MenuItemMissing;
    try std.testing.expect(zig_event == .zig);
    try std.testing.expectEqual(@as(usize, 6), template.app.menu_targets.keys().len);
    for ([_][]const u8{ "toggle-devtools", "quit" }) |action| {
        try std.testing.expect(template.app.menu_targets.get(action) == null);
        const wanted = try std.fmt.allocPrint(std.testing.allocator, "\"action\":\"{s}\"", .{action});
        defer std.testing.allocator.free(wanted);
        try std.testing.expect(std.mem.indexOf(u8, template.app.menu_json, wanted) != null);
    }
}

test "the zig-event item's function sends the UI the app event menu-zig-event" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), template.app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"zig-event\"}}");
    try shell.expectMessageContaining("{\"kind\":\"app\",\"data\":{\"type\":\"menu-zig-event\"}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":true,\"data\":{}}");
}
