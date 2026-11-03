const std = @import("std");
const ziggy = @import("ziggy");
const windows_actions = @import("ziggy-native-windows-actions");

//
// The function of the `.zig` item of the menu below. It is never called: the tests only look it up.
//
fn chosen(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!void {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
}

//
// The actions of the menu below: three it has `.action` items for and one, "hidden", that is not on it.
//
const every_kind_actions: []const ziggy.action.Action = &.{
    .{
        .name = "open",
        .label = "Open",
        .shortcut = "CmdOrCtrl+O",
    },
    .{
        .name = "save",
        .label = "Save",
        .shortcut = "CmdOrCtrl+S",
    },
    .{
        .name = "find",
        .label = "Find",
    },
    .{
        .name = "hidden",
        .label = "Hidden",
        .shortcut = "CmdOrCtrl+H",
    },
};

//
// A menu with every kind of item: a standard item, a `.zig` item, a `.ui` item, `.action` items (one showing its action's label and
// shortcut, one with its own label and one with its own shortcut), a separator and a submenu holding a `.ui` item and a standard item.
//
const every_kind: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .label = "Quit",
                .shortcut = "CmdOrCtrl+Q",
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
            .{
                .run = .{
                    .action = "open",
                },
            },
            .{
                .label = "Save As",
                .run = .{
                    .action = "save",
                },
            },
            .{
                .shortcut = "CmdOrCtrl+F",
                .run = .{
                    .action = "find",
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
                .shortcut = "F1",
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
                    .{
                        .label = "Zoom In",
                        .shortcut = "CmdOrCtrl+Plus",
                        .run = .{
                            .standard = .@"zoom-in",
                        },
                    },
                },
            },
        },
    },
};

//
// One menu entry as a test expects it, with plain strings in place of the C strings the core gives.
//
const ExpectedEntry = struct {
    // What the entry is.
    kind: ziggy.menu.MenuEntryKind,
    // How deep the entry is.
    depth: u32,
    // The text it shows, or null.
    label: ?[]const u8,
    // What an item runs, or null.
    action: ?[]const u8,
    // An item's shortcut text, or null.
    shortcut: ?[]const u8,
};

//
// Fails unless a C string the core gives is the expected text, both null or both the same.
//
fn expectCString(expected: ?[]const u8, actual: ?[*:0]const u8) !void {
    if (expected) |text| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(text, std.mem.span(actual.?));
    }
    else {
        try std.testing.expect(actual == null);
    }
}

test "menuEntries flattens every kind of item in order, with its depth, label, action and shortcut" {
    const expected = [_]ExpectedEntry{
        .{
            .kind = .menu,
            .depth = 0,
            .label = "File",
            .action = null,
            .shortcut = null,
        },
        .{
            .kind = .item,
            .depth = 1,
            .label = "Quit",
            .action = "quit",
            .shortcut = "CmdOrCtrl+Q",
        },
        .{
            .kind = .separator,
            .depth = 1,
            .label = null,
            .action = null,
            .shortcut = null,
        },
        .{
            .kind = .item,
            .depth = 1,
            .label = "Run \"Zig\"",
            .action = "run-zig",
            .shortcut = null,
        },
        .{
            .kind = .item,
            .depth = 1,
            .label = "Open",
            .action = "open",
            .shortcut = "CmdOrCtrl+O",
        },
        .{
            .kind = .item,
            .depth = 1,
            .label = "Save As",
            .action = "save",
            .shortcut = "CmdOrCtrl+S",
        },
        .{
            .kind = .item,
            .depth = 1,
            .label = "Find",
            .action = "find",
            .shortcut = "CmdOrCtrl+F",
        },
        .{
            .kind = .menu,
            .depth = 0,
            .label = "Help",
            .action = null,
            .shortcut = null,
        },
        .{
            .kind = .item,
            .depth = 1,
            .label = "About",
            .action = "about",
            .shortcut = "F1",
        },
        .{
            .kind = .submenu,
            .depth = 1,
            .label = "More",
            .action = null,
            .shortcut = null,
        },
        .{
            .kind = .item,
            .depth = 2,
            .label = "Nested",
            .action = "nested",
            .shortcut = null,
        },
        .{
            .kind = .item,
            .depth = 2,
            .label = "Zoom In",
            .action = "zoom-in",
            .shortcut = "CmdOrCtrl+Plus",
        },
    };
    const entries = comptime ziggy.menu.menuEntries(every_kind, every_kind_actions);
    try std.testing.expectEqual(expected.len, entries.len);
    for (expected, entries) |wanted, entry| {
        try std.testing.expectEqual(wanted.kind, entry.kind);
        try std.testing.expectEqual(wanted.depth, entry.depth);
        try expectCString(wanted.label, entry.label);
        try expectCString(wanted.action, entry.action);
        try expectCString(wanted.shortcut, entry.shortcut);
    }
}

test "menuEntries of an empty menu is empty" {
    try std.testing.expectEqual(@as(usize, 0), (comptime ziggy.menu.menuEntries(&.{}, &.{})).len);
}

test "menuTargets holds every action as .action, on the menu or not" {
    const targets = comptime ziggy.menu.menuTargets(every_kind, every_kind_actions);
    inline for (.{ "open", "save", "find", "hidden" }) |name| {
        const target = targets.get(name) orelse return error.MenuItemMissing;
        try std.testing.expect(target == .action);
    }
}

test "standardMenuItems holds every .standard item, those in submenus included, with its label and shortcut" {
    const items = comptime ziggy.menu.standardMenuItems(every_kind);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(ziggy.menu.StandardAction.quit, items[0].action);
    try std.testing.expectEqualStrings("Quit", items[0].label);
    try std.testing.expectEqualStrings("CmdOrCtrl+Q", items[0].shortcut.?);
    try std.testing.expectEqual(ziggy.menu.StandardAction.@"zoom-in", items[1].action);
    try std.testing.expectEqualStrings("Zoom In", items[1].label);
    try std.testing.expectEqualStrings("CmdOrCtrl+Plus", items[1].shortcut.?);
}

test "menuTargets maps each .zig and .ui item (those in submenus included) and each action, and holds no standard item or separator" {
    const targets = comptime ziggy.menu.menuTargets(every_kind, every_kind_actions);
    try std.testing.expectEqual(@as(usize, 3 + every_kind_actions.len), targets.keys().len);
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
