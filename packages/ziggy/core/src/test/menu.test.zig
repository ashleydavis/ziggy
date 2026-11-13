const std = @import("std");
const builtin = @import("builtin");
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

//
// The actions the typing shortcut tests use: one with Enter, one with no shortcut, and two with the same key press.
//
const typing_actions: []const ziggy.action.Action = &.{
    .{
        .name = "enter-action",
        .label = "Enter Action",
        .shortcut = "Enter",
    },
    .{
        .name = "plain-action",
        .label = "Plain Action",
    },
};

//
// Menus with one typing shortcut each: a `.standard` item on Escape, a `.zig` item on Down and an item in a submenu on ?. The last
// menu's `.action` item leaves its shortcut out, so it shows its action's Enter.
//
const escape_menu: []const ziggy.menu.Menu = &.{
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
            .{
                .label = "Escape",
                .shortcut = "Escape",
                .run = .{
                    .standard = .reload,
                },
            },
        },
    },
};

const down_menu: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .label = "Down",
                .name = "down",
                .shortcut = "Down",
                .run = .ui,
            },
        },
    },
};

const question_mark_menu: []const ziggy.menu.Menu = &.{
    .{
        .label = "Help",
        .items = &.{
            .{
                .label = "More",
                .items = &.{
                    .{
                        .label = "Question",
                        .shortcut = "?",
                        .run = .{
                            .standard = .reload,
                        },
                    },
                },
            },
        },
    },
};

const action_typing_menu: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .run = .{
                    .action = "enter-action",
                },
            },
        },
    },
};

test "menu_typing_shortcut_item gives the label of the first item with a typing shortcut" {
    try std.testing.expectEqualStrings("Escape", (comptime ziggy.menu.menu_typing_shortcut_item(escape_menu, &.{}) catch unreachable).?);
    try std.testing.expectEqualStrings("Down", (comptime ziggy.menu.menu_typing_shortcut_item(down_menu, &.{}) catch unreachable).?);
    // The item is in a submenu.
    try std.testing.expectEqualStrings("Question", (comptime ziggy.menu.menu_typing_shortcut_item(question_mark_menu, &.{}) catch unreachable).?);
    // The .action item's shortcut comes from its action.
    try std.testing.expectEqualStrings("Enter Action", (comptime ziggy.menu.menu_typing_shortcut_item(action_typing_menu, typing_actions) catch unreachable).?);
}

test "menu_typing_shortcut_item gives null when no item has a typing shortcut" {
    try std.testing.expect((comptime ziggy.menu.menu_typing_shortcut_item(every_kind, every_kind_actions) catch unreachable) == null);
    try std.testing.expect((comptime ziggy.menu.menu_typing_shortcut_item(&.{}, &.{}) catch unreachable) == null);
}

test "menu_typing_shortcut_item gives the parse error of a shortcut that does not parse" {
    comptime {
        const result = ziggy.menu.menu_typing_shortcut_item(unparseable_menu, &.{});
        if (result) |_| {
            @compileError("a shortcut that does not parse must give its parse error");
        }
        else |err| {
            if (err != error.UnknownKey) {
                @compileError("a shortcut that does not parse must give UnknownKey");
            }
        }
    }
}

test "off_menu_key_press_clash gives the two actions whose off-menu shortcuts are the same key press" {
    const plus_and_equal = comptime ziggy.menu.off_menu_key_press_clash(&.{}, plus_equal_actions) catch unreachable;
    try std.testing.expectEqual(@as(usize, 2), plus_and_equal.?.len);
    try std.testing.expectEqualStrings("zoom-in", plus_and_equal.?[0]);
    try std.testing.expectEqualStrings("zoom-out", plus_and_equal.?[1]);
    const escapes = comptime ziggy.menu.off_menu_key_press_clash(&.{}, escape_actions) catch unreachable;
    try std.testing.expectEqualStrings("first-escape", escapes.?[0]);
    try std.testing.expectEqualStrings("second-escape", escapes.?[1]);
}

test "off_menu_key_press_clash gives null when no two off-menu actions share a key press" {
    try std.testing.expect((comptime ziggy.menu.off_menu_key_press_clash(&.{}, &.{}) catch unreachable) == null);
    try std.testing.expect((comptime ziggy.menu.off_menu_key_press_clash(&.{}, different_actions) catch unreachable) == null);
    // The menu comparison covers a pair where one action has a menu item.
    try std.testing.expect((comptime ziggy.menu.off_menu_key_press_clash(action_menu_for_first, escape_actions) catch unreachable) == null);
}

test "off_menu_key_press_clash counts Ctrl and CmdOrCtrl as one key press away from macOS" {
    const clash = comptime ziggy.menu.off_menu_key_press_clash(&.{}, ctrl_and_cmd_actions) catch unreachable;
    if (builtin.os.tag == .macos) {
        try std.testing.expect(clash == null);
    }
    else {
        try std.testing.expectEqualStrings("ctrl-s", clash.?[0]);
        try std.testing.expectEqualStrings("cmd-or-ctrl-s", clash.?[1]);
    }
}

test "off_menu_key_press_clash gives the parse error of a shortcut that does not parse" {
    comptime {
        const result = ziggy.menu.off_menu_key_press_clash(&.{}, unparseable_actions);
        if (result) |_| {
            @compileError("a shortcut that does not parse must give its parse error");
        }
        else |err| {
            if (err != error.UnknownKey) {
                @compileError("a shortcut that does not parse must give UnknownKey");
            }
        }
    }
}

//
// A menu with an item whose shortcut does not parse.
//
const unparseable_menu: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .label = "Banana",
                .shortcut = "Banana",
                .run = .{
                    .standard = .reload,
                },
            },
        },
    },
};

//
// Two off-menu actions on CmdOrCtrl+Plus and CmdOrCtrl+Equal, which are the same key press.
//
const plus_equal_actions: []const ziggy.action.Action = &.{
    .{
        .name = "zoom-in",
        .label = "Zoom In",
        .shortcut = "CmdOrCtrl+Plus",
    },
    .{
        .name = "zoom-out",
        .label = "Zoom Out",
        .shortcut = "CmdOrCtrl+Equal",
    },
};

//
// Two off-menu actions on Escape.
//
const escape_actions: []const ziggy.action.Action = &.{
    .{
        .name = "first-escape",
        .label = "First Escape",
        .shortcut = "Escape",
    },
    .{
        .name = "second-escape",
        .label = "Second Escape",
        .shortcut = "Escape",
    },
};

//
// Two off-menu actions on different keys.
//
const different_actions: []const ziggy.action.Action = &.{
    .{
        .name = "up-action",
        .label = "Up Action",
        .shortcut = "Up",
    },
    .{
        .name = "down-action",
        .label = "Down Action",
        .shortcut = "Down",
    },
};

//
// A menu with an `.action` item for the first of the escape actions.
//
const action_menu_for_first: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .run = .{
                    .action = "first-escape",
                },
            },
        },
    },
};

//
// Two off-menu actions on Ctrl+S and CmdOrCtrl+S, which are the same key press away from macOS.
//
const ctrl_and_cmd_actions: []const ziggy.action.Action = &.{
    .{
        .name = "ctrl-s",
        .label = "Ctrl S",
        .shortcut = "Ctrl+S",
    },
    .{
        .name = "cmd-or-ctrl-s",
        .label = "Cmd Or Ctrl S",
        .shortcut = "CmdOrCtrl+S",
    },
};

//
// Two actions, one of whose shortcuts does not parse.
//
const unparseable_actions: []const ziggy.action.Action = &.{
    .{
        .name = "banana",
        .label = "Banana",
        .shortcut = "Banana",
    },
    .{
        .name = "escape",
        .label = "Escape",
        .shortcut = "Escape",
    },
};

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
