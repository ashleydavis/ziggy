const std = @import("std");
const ziggy = @import("ziggy");
const windows_actions = @import("ziggy-native-windows-actions");

//
// The function of the `.zig` item of the menu below. It is never called: the tests only look it up.
//
fn chosen(core: *ziggy.core.Core, arena: std.mem.Allocator) anyerror!void {
    _ = core;
    _ = arena;
}

//
// A menu with every kind of item: a standard item, a `.zig` item, a `.ui` item, a separator and a submenu holding a `.ui` item.
//
const every_kind: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .label = "Quit",
                .accelerator = "CmdOrCtrl+Q",
                .run = .{
                    .standard = .quit,
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Run \"Zig\"",
                .name = "run-zig",
                .run = .{
                    .zig = chosen,
                },
            },
        },
    },
    .{
        .label = "Help",
        .items = &.{
            .{
                .label = "About",
                .name = "about",
                .accelerator = "F1",
                .run = .ui,
            },
            .{
                .label = "More",
                .items = &.{
                    .{
                        .label = "Nested",
                        .name = "nested",
                        .run = .ui,
                    },
                },
            },
        },
    },
};

test "menuJson gives the JSON the native apps read for every kind of item" {
    try std.testing.expectEqualStrings(
        "[{\"label\":\"File\",\"items\":[{\"label\":\"Quit\",\"action\":\"quit\",\"accelerator\":\"CmdOrCtrl+Q\"},{\"separator\":true}," ++
            "{\"label\":\"Run \\\"Zig\\\"\",\"action\":\"run-zig\"}]}," ++
            "{\"label\":\"Help\",\"items\":[{\"label\":\"About\",\"action\":\"about\",\"accelerator\":\"F1\"}," ++
            "{\"label\":\"More\",\"items\":[{\"label\":\"Nested\",\"action\":\"nested\"}]}]}]",
        comptime ziggy.menu.menuJson(every_kind),
    );
}

test "menuJson of an empty menu is []" {
    try std.testing.expectEqualStrings("[]", comptime ziggy.menu.menuJson(&.{}));
}

test "menuTargets maps each .zig and .ui item (those in submenus included) and holds no standard item or separator" {
    const targets = comptime ziggy.menu.menuTargets(every_kind);
    try std.testing.expectEqual(@as(usize, 3), targets.keys().len);
    const run_zig = targets.get("run-zig") orelse return error.MenuItemMissing;
    try std.testing.expect(run_zig.zig == &chosen);
    const about = targets.get("about") orelse return error.MenuItemMissing;
    try std.testing.expect(about == .ui);
    const nested = targets.get("nested") orelse return error.MenuItemMissing;
    try std.testing.expect(nested == .ui);
    try std.testing.expect(targets.get("quit") == null);
    try std.testing.expect(targets.get("") == null);
}

test "StandardAction has a tag for every action the Windows native app does itself, and no other" {
    inline for (@typeInfo(windows_actions.Action).@"enum".fields) |field| {
        var hyphenated: [field.name.len]u8 = undefined;
        for (field.name, 0..) |byte, index| {
            hyphenated[index] = if (byte == '_') '-' else byte;
        }
        try std.testing.expect(std.meta.stringToEnum(ziggy.menu.StandardAction, &hyphenated) != null);
    }
    inline for (@typeInfo(ziggy.menu.StandardAction).@"enum".fields) |field| {
        try std.testing.expect(windows_actions.fromName(field.name) != null);
    }
}
