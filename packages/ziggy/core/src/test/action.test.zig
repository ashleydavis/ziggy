const std = @import("std");
const ziggy = @import("ziggy");

//
// Actions that pass every check: one with a shortcut on the menu below, one with a shortcut that is not on it and one with no shortcut.
//
const actions: []const ziggy.action.Action = &.{
    .{
        .name = "open",
        .label = "Open",
        .shortcut = "CmdOrCtrl+O",
    },
    .{
        .name = "palette",
        .label = "Show the Command Palette",
        .shortcut = "CmdOrCtrl+Shift+P",
    },
    .{
        .name = "plain",
        .label = "Plain",
    },
};

//
// A menu with an `.action` item for "open" only.
//
const menu: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .run = .{
                    .action = "open",
                },
            },
        },
    },
};

test "rejectInvalidActions accepts actions with unique names, labels and shortcuts that parse" {
    comptime ziggy.action.rejectInvalidActions(actions);
}

test "rejectInvalidActions accepts no actions" {
    comptime ziggy.action.rejectInvalidActions(&.{});
}

test "standaloneActionShortcuts lists only the actions that have a shortcut and no .action item on the menu" {
    const shortcuts = comptime ziggy.action.standaloneActionShortcuts(menu, actions);
    try std.testing.expectEqual(@as(usize, 1), shortcuts.len);
    try std.testing.expectEqualStrings("palette", std.mem.span(shortcuts[0].action));
    try std.testing.expectEqualStrings("CmdOrCtrl+Shift+P", std.mem.span(shortcuts[0].shortcut));
}

test "standaloneActionShortcuts of an app with no actions is empty" {
    try std.testing.expectEqual(@as(usize, 0), (comptime ziggy.action.standaloneActionShortcuts(menu, &.{})).len);
}
