//
// ziggy.menu: the desktop menu an app gives ziggy.core.App as `.menu`. Each item names what it runs: a standard action the native app
// does itself, a Zig function the core calls, the frontend, which receives the item as the app event
// {"type": "menu", "item": "<name>"}, or one of the app's actions (see ziggy.action). App checks the menu when the app is built. The
// core gives the native apps the same menu as JSON text, made from it at compile time.
//

const std = @import("std");
const builtin = @import("builtin");
const services_lib = @import("services.zig");
const timers_lib = @import("timers.zig");
const shortcut_lib = @import("shortcut.zig");
const action_lib = @import("action.zig");

//
// The actions the native apps do themselves, each tag spelled as the native apps match it in the menu JSON.
//
pub const StandardAction = enum {
    quit,
    @"close-window",
    reload,
    @"toggle-devtools",
    @"toggle-fullscreen",
    @"zoom-in",
    @"zoom-out",
    @"zoom-reset",
    undo,
    redo,
    cut,
    copy,
    paste,
    @"select-all",
    @"focus-window",
};

//
// A Zig function a menu item runs. The main thread calls it with the same standard arguments as a message handler (the handler
// services, the timers, the Io and the allocator of the menu-action message), with no payload and no reply, so slow work queues a task
// from it. Its error is reported as the error of that message.
//
pub const MenuFn = *const fn (services: services_lib.HandlerServices, timers: timers_lib.Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!void;

//
// What a menu item runs when it is chosen.
//
pub const Run = union(enum) {
    // An action the native app does itself.
    standard: StandardAction,
    // A Zig function the core calls.
    zig: MenuFn,
    // The frontend, which receives the app event {"type": "menu", "item": "<name>"}.
    ui: void,
    // One of the app's actions, by its name. Its handler in the frontend runs.
    action: []const u8,
};

//
// One item of a menu: a separator, a submenu (with `items`) or an item that runs something (with `run`).
//
pub const Item = struct {
    // The text the item shows. Empty for a separator, and left empty by an `.action` item that shows its action's label.
    label: []const u8 = "",
    // The name the core finds the item by, which a `.zig` or `.ui` item must have and a `.standard` or `.action` item must not. A
    // `.ui` item's name is the `item` of the event the frontend receives.
    name: ?[]const u8 = null,
    // The keyboard shortcut, such as "CmdOrCtrl+Shift+I", or null for none. An `.action` item with none shows its action's.
    shortcut: ?[]const u8 = null,
    // What the item runs, or null for a separator or a submenu.
    run: ?Run = null,
    // The items of a submenu, or null for an item that is not one.
    items: ?[]const Item = null,
    // Whether the item is a separator.
    separator: bool = false,
};

//
// A separator between two items.
//
pub const separator: Item = .{
    .label = "",
    .separator = true,
};

//
// One menu of the menu bar.
//
pub const Menu = struct {
    // The text the menu shows in the menu bar.
    label: []const u8,
    // The menu's items.
    items: []const Item,
};

//
// What the core does for a menu item a native app posts: call a Zig function, send the frontend the item as an app event, or run one of
// the app's actions.
//
pub const MenuTarget = union(enum) {
    // The Zig function the core calls.
    zig: MenuFn,
    // The frontend, which receives the app event {"type": "menu", "item": "<name>"}.
    ui: void,
    // One of the app's actions, whose handler in the frontend runs.
    action: void,
};

//
// The table from the name of each `.zig` and `.ui` item, and of each of the app's actions, to what the core does for it.
//
pub const MenuTargets = std.StaticStringMap(MenuTarget);

//
// One `.standard` item of the menu, as window.ziggy.listActions lists it and runAction checks it.
//
pub const StandardMenuItem = struct {
    // The standard action the item runs.
    action: StandardAction,
    // The text the item shows.
    label: []const u8,
    // The item's keyboard shortcut, or null for none.
    shortcut: ?[]const u8,
};

//
// Fails the build, naming the item, when the menu is wrong: an item that is neither a separator, a submenu nor has a `run`, a submenu
// that also has a `run`, a `.zig` or `.ui` item with no name or with an action's name, a `.standard` or `.action` item with a name, an
// `.action` item naming an action the app does not have, two `.action` items running the same action, an empty label, two items
// with the same name, a name spelled like a standard action, two shortcuts that are the same key press, a shortcut that does not
// parse, or an item with a typing shortcut. The shortcuts compared are each item's own, an `.action` item's action's when it has
// none, and those of the actions that are not on the menu.
//
pub fn rejectInvalidMenu(comptime menu: []const Menu, comptime actions: []const action_lib.Action) void {
    comptime {
        @setEvalBranchQuota(100_000);
        const items = allItems(menu);
        for (items, 0..) |item, index| {
            rejectInvalidMenuItem(item, actions);
            for (items[0..index]) |earlier| {
                if (item.name != null and earlier.name != null and std.mem.eql(u8, item.name.?, earlier.name.?)) {
                    @compileError("ziggy.menu: the items \"" ++ earlier.label ++ "\" and \"" ++ item.label ++ "\" have the same name \"" ++ item.name.? ++ "\".");
                }
                const item_shortcut = menuItemShortcut(item, actions);
                const earlier_shortcut = menuItemShortcut(earlier, actions);
                if (item_shortcut != null and earlier_shortcut != null) {
                    const same = sameKeyPressTexts(earlier_shortcut.?, item_shortcut.?) catch |err| {
                        @compileError(shortcutParseError(menu, actions, err));
                    };
                    if (same) {
                        @compileError("ziggy.menu: the items \"" ++ menuItemLabel(earlier, actions) ++ "\" and \"" ++ menuItemLabel(item, actions) ++ "\" have the same key press, \"" ++ earlier_shortcut.? ++ "\" and \"" ++ item_shortcut.? ++ "\".");
                    }
                }
                if (menuItemActionName(item) != null and menuItemActionName(earlier) != null and std.mem.eql(u8, menuItemActionName(item).?, menuItemActionName(earlier).?)) {
                    @compileError("ziggy.menu: two items run the action \"" ++ menuItemActionName(item).? ++ "\".");
                }
            }
            if (item.name) |name| {
                if (findAppAction(actions, name) != null) {
                    @compileError("ziggy.menu: the item \"" ++ item.label ++ "\" has the name \"" ++ name ++ "\", which is the name of one of the app's actions.");
                }
            }
            const shortcut = menuItemShortcut(item, actions) orelse continue;
            for (actions) |action| {
                const action_shortcut = action.shortcut orelse continue;
                if (hasActionMenuItem(menu, action.name)) {
                    continue;
                }
                const same = sameKeyPressTexts(shortcut, action_shortcut) catch |err| {
                    @compileError(shortcutParseError(menu, actions, err));
                };
                if (same) {
                    @compileError("ziggy.menu: the item \"" ++ menuItemLabel(item, actions) ++ "\" and the action \"" ++ action.name ++ "\" have the same key press, \"" ++ shortcut ++ "\" and \"" ++ action_shortcut ++ "\".");
                }
            }
        }
        const typing_label = menu_typing_shortcut_item(menu, actions) catch |err| {
            @compileError(shortcutParseError(menu, actions, err));
        };
        if (typing_label) |label| {
            @compileError("ziggy.menu: the item \"" ++ label ++ "\" has a shortcut with no Ctrl, Alt or Cmd that is not a function key. Typing shortcuts are never shown in a menu: take the item off the menu and keep the shortcut on an action, or give the shortcut Ctrl, Alt or Cmd.");
        }
        const clash = off_menu_key_press_clash(menu, actions) catch |err| {
            @compileError(shortcutParseError(menu, actions, err));
        };
        if (clash) |pair| {
            @compileError("ziggy.menu: the actions \"" ++ pair[0] ++ "\" and \"" ++ pair[1] ++ "\" have the same key press, \"" ++ actionShortcut(actions, pair[0]) ++ "\" and \"" ++ actionShortcut(actions, pair[1]) ++ "\".");
        }
    }
}

//
// Whether two shortcut texts are the same key press, or the parse error of the first that does not parse.
//
pub fn sameKeyPressTexts(comptime first: []const u8, comptime second: []const u8) shortcut_lib.ParseError!bool {
    const first_parsed = try shortcut_lib.parse(first);
    const second_parsed = try shortcut_lib.parse(second);
    return shortcut_lib.is_same_key_press(first_parsed, second_parsed);
}

//
// The build failure for a shortcut that does not parse, naming the first one that does not.
//
pub fn shortcutParseError(comptime menu: []const Menu, comptime actions: []const action_lib.Action, comptime err: shortcut_lib.ParseError) []const u8 {
    const text = firstUnparseableShortcut(menu, actions) orelse "";
    return "ziggy.menu: the shortcut \"" ++ text ++ "\" does not parse: " ++ @errorName(err) ++ ".";
}

//
// The first shortcut text in the menu or in the actions that are not on it that does not parse, or null when every one does.
//
pub fn firstUnparseableShortcut(comptime menu: []const Menu, comptime actions: []const action_lib.Action) ?[]const u8 {
    comptime {
        for (allItems(menu)) |item| {
            const shortcut = menuItemShortcut(item, actions) orelse continue;
            _ = shortcut_lib.parse(shortcut) catch return shortcut;
        }
        for (actions) |action| {
            const shortcut = action.shortcut orelse continue;
            if (hasActionMenuItem(menu, action.name)) {
                continue;
            }
            _ = shortcut_lib.parse(shortcut) catch return shortcut;
        }
        return null;
    }
}

//
// The label of the first item, of any kind and in a submenu or not, whose shortcut parses and has no Ctrl, Alt or Cmd, or null when
// no item has one. A typing shortcut is one the frontend runs, so it is never shown in a menu. The parse error is given when a
// shortcut does not parse.
//
pub fn menu_typing_shortcut_item(comptime menu: []const Menu, comptime actions: []const action_lib.Action) shortcut_lib.ParseError!?[]const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        for (allItems(menu)) |item| {
            const shortcut = menuItemShortcut(item, actions) orelse continue;
            const parsed = try shortcut_lib.parse(shortcut);
            if (!shortcut_lib.is_text_box_key(parsed)) {
                continue;
            }
            const label = menuItemLabel(item, actions);
            std.debug.assert(label.len > 0);
            std.debug.assert(allItems(menu).len > 0);
            return label;
        }
        return null;
    }
}

//
// The names of the first two of the app's actions that have a shortcut and no menu item and whose shortcuts are the same key press, or
// null when no two are. The parse error is given when a shortcut does not parse.
//
pub fn off_menu_key_press_clash(comptime menu: []const Menu, comptime actions: []const action_lib.Action) shortcut_lib.ParseError!?[2][]const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var off_menu: []const action_lib.Action = &.{};
        for (actions) |action| {
            if (action.shortcut == null) {
                continue;
            }
            if (hasActionMenuItem(menu, action.name)) {
                continue;
            }
            off_menu = off_menu ++ &[_]action_lib.Action{action};
        }
        for (off_menu) |action| {
            _ = try shortcut_lib.parse(action.shortcut.?);
        }
        for (off_menu, 0..) |action, index| {
            for (off_menu[0..index]) |earlier| {
                const earlier_parsed = try shortcut_lib.parse(earlier.shortcut.?);
                const action_parsed = try shortcut_lib.parse(action.shortcut.?);
                if (shortcut_lib.is_same_key_press(earlier_parsed, action_parsed)) {
                    std.debug.assert(!std.mem.eql(u8, earlier.name, action.name));
                    std.debug.assert(earlier.shortcut != null);
                    std.debug.assert(action.shortcut != null);
                    return .{ earlier.name, action.name };
                }
            }
        }
        return null;
    }
}

//
// The shortcut text of the action with the name, or an empty string when no action has the name.
//
pub fn actionShortcut(comptime actions: []const action_lib.Action, comptime name: []const u8) []const u8 {
    comptime {
        for (actions) |action| {
            if (std.mem.eql(u8, action.name, name)) {
                std.debug.assert(action.shortcut != null);
                return action.shortcut.?;
            }
        }
        return "";
    }
}

//
// Fails the build when one item is wrong on its own (see rejectInvalidMenu).
//
fn rejectInvalidMenuItem(comptime item: Item, comptime actions: []const action_lib.Action) void {
    const label = "ziggy.menu: the item \"" ++ item.label ++ "\"";
    if (item.separator) {
        if (item.run != null or item.items != null or item.name != null or item.shortcut != null) {
            @compileError("ziggy.menu: a separator has no run, items, name or shortcut. Use ziggy.menu.separator.");
        }
        return;
    }
    if (item.run == null or item.run.? != .action) {
        if (item.label.len == 0) {
            @compileError("ziggy.menu: an item that is not a separator has an empty label. Only an item that runs an action may leave it out.");
        }
    }
    if (item.items != null) {
        if (item.run != null) {
            @compileError(label ++ " has a submenu and a run. A submenu runs nothing itself.");
        }
        if (item.name != null) {
            @compileError(label ++ " has a submenu and a name. Only an item that runs something has a name.");
        }
    }
    else {
        const run = item.run orelse {
            @compileError(label ++ " is neither a separator nor a submenu and has no run.");
        };
        switch (run) {
            .standard => {
                if (item.name != null) {
                    @compileError(label ++ " runs a standard action and has a name. A standard action is named by its action.");
                }
            },
            .zig, .ui => {
                const name = item.name orelse {
                    @compileError(label ++ " runs " ++ (if (run == .zig) "a Zig function" else "the UI") ++ " and has no name.");
                };
                if (name.len == 0) {
                    @compileError(label ++ " has an empty name.");
                }
                if (std.meta.stringToEnum(StandardAction, name) != null) {
                    @compileError(label ++ " is named \"" ++ name ++ "\", which is the name of a standard action.");
                }
            },
            .action => |action_name| {
                if (item.name != null) {
                    @compileError("ziggy.menu: the item that runs the action \"" ++ action_name ++ "\" has a name. An item that runs an action is named by its action.");
                }
                if (findAppAction(actions, action_name) == null) {
                    @compileError("ziggy.menu: an item runs the action \"" ++ action_name ++ "\", which is not one of the app's actions.");
                }
            },
        }
    }
    if (item.shortcut) |text| {
        _ = shortcut_lib.parse(text) catch |err| {
            @compileError(label ++ " has the shortcut \"" ++ text ++ "\", which does not parse: " ++ @errorName(err) ++ ".");
        };
    }
}

//
// Every item of the menu, those of submenus included, in the order they appear.
//
fn allItems(comptime menu: []const Menu) []const Item {
    comptime {
        var items: []const Item = &.{};
        for (menu) |each| {
            items = items ++ itemsOf(each.items);
        }
        return items;
    }
}

//
// The items given and, after each submenu, its own items, however deep.
//
fn itemsOf(comptime items: []const Item) []const Item {
    comptime {
        var found: []const Item = &.{};
        for (items) |item| {
            found = found ++ &[_]Item{item};
            if (item.items) |children| {
                found = found ++ itemsOf(children);
            }
        }
        return found;
    }
}

//
// The name of the action an `.action` item runs, or null for any other item.
//
fn menuItemActionName(comptime item: Item) ?[]const u8 {
    const run = item.run orelse return null;
    return switch (run) {
        .action => |name| name,
        else => null,
    };
}

//
// The app's action with the name, or null when it has none.
//
fn findAppAction(comptime actions: []const action_lib.Action, comptime name: []const u8) ?action_lib.Action {
    for (actions) |action| {
        if (std.mem.eql(u8, action.name, name)) {
            return action;
        }
    }
    return null;
}

//
// The shortcut an item shows: its own, or for an `.action` item with none, its action's.
//
fn menuItemShortcut(comptime item: Item, comptime actions: []const action_lib.Action) ?[]const u8 {
    if (item.shortcut != null) {
        return item.shortcut;
    }
    const name = menuItemActionName(item) orelse return null;
    const action = findAppAction(actions, name) orelse return null;
    return action.shortcut;
}

//
// The label an item shows: its own, or for an `.action` item that leaves it empty, its action's.
//
fn menuItemLabel(comptime item: Item, comptime actions: []const action_lib.Action) []const u8 {
    if (item.label.len > 0) {
        return item.label;
    }
    const name = menuItemActionName(item) orelse return item.label;
    const action = findAppAction(actions, name) orelse return item.label;
    return action.label;
}

//
// Whether the menu has an `.action` item that runs the action with the name.
//
pub fn hasActionMenuItem(comptime menu: []const Menu, comptime name: []const u8) bool {
    comptime {
        @setEvalBranchQuota(100_000);
        for (allItems(menu)) |item| {
            const action_name = menuItemActionName(item) orelse continue;
            if (std.mem.eql(u8, action_name, name)) {
                return true;
            }
        }
        return false;
    }
}

//
// What a menu entry is, as ziggy.h numbers it.
//
pub const MenuEntryKind = enum(u32) {
    // A menu of the menu bar, followed by its entries.
    menu = 0,
    // An item that runs something.
    item = 1,
    // A separator line.
    separator = 2,
    // A submenu, followed by its entries.
    submenu = 3,
};

//
// One entry of the menu as a desktop native app reads it through ziggy_menu: the menu flattened in order, each menu and submenu followed
// by its entries. It is laid out as ziggy.h's ziggy_menu_entry, so a native app reads the array the core holds without copying it.
//
pub const MenuEntry = extern struct {
    // What the entry is, a MenuEntryKind.
    kind: MenuEntryKind,
    // How deep the entry is: 0 for a menu of the menu bar, 1 for its entries and one more inside each submenu.
    depth: u32,
    // The text the entry shows, or null for a separator.
    label: ?[*:0]const u8,
    // What an item runs: its standard action for a `.standard` item, its action's name for an `.action` item and its name otherwise.
    // Null for any other entry.
    action: ?[*:0]const u8,
    // An item's shortcut as the platform shows it, such as "Ctrl+Shift+I" or "⇧⌘H", its own or for an `.action` item its
    // action's, or null for none.
    shortcut: ?[*:0]const u8,
};

//
// Makes the menu's entries at compile time, as the native apps read them through ziggy_menu. An `.action` item's label and shortcut
// are its action's unless it sets its own.
//
pub fn menuEntries(comptime menu: []const Menu, comptime actions: []const action_lib.Action) []const MenuEntry {
    return comptime made: {
        @setEvalBranchQuota(1_000_000);
        var entries: []const MenuEntry = &.{};
        for (menu) |each| {
            entries = entries ++ &[_]MenuEntry{.{
                .kind = .menu,
                .depth = 0,
                .label = cString(each.label),
                .action = null,
                .shortcut = null,
            }};
            entries = entries ++ menuItemEntries(each.items, actions, 1);
        }
        const result = entries[0..entries.len].*;
        break :made &result;
    };
}

//
// Makes the menu entries of the menu items given, at the depth given, each submenu followed by its own entries one deeper.
//
fn menuItemEntries(comptime items: []const Item, comptime actions: []const action_lib.Action, comptime depth: u32) []const MenuEntry {
    comptime {
        var entries: []const MenuEntry = &.{};
        for (items) |item| {
            if (item.separator) {
                entries = entries ++ &[_]MenuEntry{.{
                    .kind = .separator,
                    .depth = depth,
                    .label = null,
                    .action = null,
                    .shortcut = null,
                }};
                continue;
            }
            if (item.items) |children| {
                entries = entries ++ &[_]MenuEntry{.{
                    .kind = .submenu,
                    .depth = depth,
                    .label = cString(item.label),
                    .action = null,
                    .shortcut = null,
                }};
                entries = entries ++ menuItemEntries(children, actions, depth + 1);
                continue;
            }
            const action = switch (item.run.?) {
                .standard => |standard| @tagName(standard),
                .zig, .ui => item.name.?,
                .action => |name| name,
            };
            const shortcut = menuItemShortcut(item, actions);
            entries = entries ++ &[_]MenuEntry{.{
                .kind = .item,
                .depth = depth,
                .label = cString(menuItemLabel(item, actions)),
                .action = cString(action),
                .shortcut = if (shortcut) |text| cString(displayShortcut(text)) else null,
            }};
        }
        return entries;
    }
}

//
// The shortcut as the platform the core is built for shows it, such as "Ctrl+Shift+I" on Linux and Windows or "⇧⌘I" on macOS.
//
pub fn displayShortcut(comptime text: []const u8) []const u8 {
    comptime {
        const parsed = shortcut_lib.parse(text) catch |err| {
            @compileError("ziggy.menu: the shortcut \"" ++ text ++ "\" does not parse: " ++ @errorName(err) ++ ".");
        };
        const written = blk: {
            var storage: [64]u8 = undefined;
            const text_written = shortcut_lib.writeDisplayText(&storage, parsed, builtin.os.tag) catch |err| {
                @compileError("ziggy.menu: the shortcut \"" ++ text ++ "\" could not be written: " ++ @errorName(err) ++ ".");
            };
            var result: [text_written.len]u8 = undefined;
            @memcpy(&result, text_written);
            break :blk result;
        };
        return &written;
    }
}

//
// Copies text into a NUL terminated string at compile time, for a C reader.
//
pub fn cString(comptime text: []const u8) [*:0]const u8 {
    return std.fmt.comptimePrint("{s}", .{text});
}

//

//
// The table from the name of each `.zig` and `.ui` item, those in submenus included, and of each of the app's actions, on the menu or
// not, to what the core does for it. Standard items, `.action` items and separators are not in it: an `.action` item is found by its
// action's name.
//
pub fn menuTargets(comptime menu: []const Menu, comptime actions: []const action_lib.Action) MenuTargets {
    return comptime made: {
        @setEvalBranchQuota(100_000);
        var entries: []const struct { []const u8, MenuTarget } = &.{};
        for (allItems(menu)) |item| {
            const run = item.run orelse continue;
            switch (run) {
                .standard, .action => {},
                .zig => |function| {
                    entries = entries ++ .{.{ item.name.?, MenuTarget{
                        .zig = function,
                    } }};
                },
                .ui => {
                    entries = entries ++ .{.{ item.name.?, MenuTarget.ui }};
                },
            }
        }
        for (actions) |action| {
            entries = entries ++ .{.{ action.name, MenuTarget.action }};
        }
        break :made MenuTargets.initComptime(entries);
    };
}

//
// One shortcut a native app posts the menu-action system message for: a `.zig`, `.ui` or `.action` item's, or an action's that has no
// menu item.
//
pub const MenuActionShortcut = struct {
    // The name the native app posts: the item's name, or the action's.
    action: []const u8,
    // The shortcut's text, such as "CmdOrCtrl+Shift+H".
    shortcut: []const u8,
};

//
// Every shortcut a native app posts menu-action for, those of the menu's items in the order they appear and then those of the actions
// that have no menu item. A `.standard` item's shortcut is not one: the native app does its action itself.
//
pub fn menuActionShortcuts(comptime menu: []const Menu, comptime actions: []const action_lib.Action) []const MenuActionShortcut {
    return comptime made: {
        @setEvalBranchQuota(100_000);
        var found: []const MenuActionShortcut = &.{};
        for (allItems(menu)) |item| {
            const run = item.run orelse continue;
            const shortcut = menuItemShortcut(item, actions) orelse continue;
            const name = switch (run) {
                .standard => continue,
                .zig, .ui => item.name.?,
                .action => |action_name| action_name,
            };
            found = found ++ &[_]MenuActionShortcut{.{
                .action = name,
                .shortcut = shortcut,
            }};
        }
        for (actions) |action| {
            const shortcut = action.shortcut orelse continue;
            if (hasActionMenuItem(menu, action.name)) {
                continue;
            }
            found = found ++ &[_]MenuActionShortcut{.{
                .action = action.name,
                .shortcut = shortcut,
            }};
        }
        const result = found[0..found.len].*;
        break :made &result;
    };
}

//
// Every `.standard` item of the menu, those of submenus included, in the order they appear.
//
pub fn standardMenuItems(comptime menu: []const Menu) []const StandardMenuItem {
    return comptime made: {
        @setEvalBranchQuota(100_000);
        var found: []const StandardMenuItem = &.{};
        for (allItems(menu)) |item| {
            const run = item.run orelse continue;
            switch (run) {
                .standard => |standard| {
                    found = found ++ &[_]StandardMenuItem{.{
                        .action = standard,
                        .label = item.label,
                        .shortcut = item.shortcut,
                    }};
                },
                else => {},
            }
        }
        const result = found[0..found.len].*;
        break :made &result;
    };
}
