const std = @import("std");
const ziggy = @import("ziggy");
const test_app = @import("test-app.zig");

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

test "standaloneActionShortcuts lists nothing, because the frontend runs every shortcut" {
    const shortcuts = comptime ziggy.action.standaloneActionShortcuts(menu, actions);
    try std.testing.expectEqual(@as(usize, 0), shortcuts.len);
}

test "standaloneActionShortcuts of an app with no actions is empty" {
    try std.testing.expectEqual(@as(usize, 0), (comptime ziggy.action.standaloneActionShortcuts(menu, &.{})).len);
}

//
// Two off-menu actions: one a native app registers, and one the frontend runs.
//
const typing_actions: []const ziggy.action.Action = &.{
    .{
        .name = "typing",
        .label = "Typing",
        .shortcut = "Escape",
    },
    .{
        .name = "command",
        .label = "Command",
        .shortcut = "CmdOrCtrl+Shift+O",
    },
};

test "standaloneActionShortcuts lists nothing for actions with shortcuts of any kind" {
    const shortcuts = comptime ziggy.action.standaloneActionShortcuts(&.{}, typing_actions);
    try std.testing.expectEqual(@as(usize, 0), shortcuts.len);
}

test "standaloneActionShortcuts of the test app lists nothing" {
    const shortcuts = comptime ziggy.action.standaloneActionShortcuts(test_app.menu, test_app.actions);
    try std.testing.expectEqual(@as(usize, 0), shortcuts.len);
}
