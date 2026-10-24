//
// ziggy.menu: the desktop menu an app gives ziggy.core.App as `.menu`. Each item names what it runs: a standard action the native app
// does itself, a Zig function the core calls, or the frontend, which receives the item as the app event
// {"type": "menu", "item": "<name>"}. App checks the menu when the app is built. The core gives the native apps the same menu as JSON text, made from it at
// compile time.
//

const std = @import("std");
const services_lib = @import("services.zig");
const timers_lib = @import("timers.zig");
const accelerator = @import("accelerator.zig");

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
};

//
// One item of a menu: a separator, a submenu (with `items`) or an item that runs something (with `run`).
//
pub const Item = struct {
    // The text the item shows. Empty for a separator.
    label: []const u8,
    // The name the core finds the item by, which a `.zig` or `.ui` item must have and a `.standard` item must not. A `.ui` item's
    // name is the `item` of the event the frontend receives.
    name: ?[]const u8 = null,
    // The keyboard shortcut, such as "CmdOrCtrl+Shift+I", or null for none.
    accelerator: ?[]const u8 = null,
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
// What the core does for a menu item a native app posts: call a Zig function, or send the frontend the item as an app event.
//
pub const MenuTarget = union(enum) {
    // The Zig function the core calls.
    zig: MenuFn,
    // The frontend, which receives the app event {"type": "menu", "item": "<name>"}.
    ui: void,
};

//
// The table from the name of each `.zig` and `.ui` item to what the core does for it.
//
pub const MenuTargets = std.StaticStringMap(MenuTarget);

//
// Fails the build, naming the item, when the menu is wrong: an item that is neither a separator, a submenu nor has a `run`, a submenu
// that also has a `run`, a `.zig` or `.ui` item with no name, a `.standard` item with a name, two items with the same name, a name
// spelled like a standard action, two items with the same shortcut or a shortcut that does not parse.
//
pub fn checkMenu(comptime menu: []const Menu) void {
    comptime {
        @setEvalBranchQuota(100_000);
        const items = allItems(menu);
        for (items, 0..) |item, index| {
            checkItem(item);
            for (items[0..index]) |earlier| {
                if (item.name != null and earlier.name != null and std.mem.eql(u8, item.name.?, earlier.name.?)) {
                    @compileError("ziggy.menu: the items \"" ++ earlier.label ++ "\" and \"" ++ item.label ++ "\" have the same name \"" ++ item.name.? ++ "\".");
                }
                if (item.accelerator != null and earlier.accelerator != null and std.mem.eql(u8, item.accelerator.?, earlier.accelerator.?)) {
                    @compileError("ziggy.menu: the items \"" ++ earlier.label ++ "\" and \"" ++ item.label ++ "\" have the same shortcut \"" ++ item.accelerator.? ++ "\".");
                }
            }
        }
    }
}

//
// Fails the build when one item is wrong on its own (see checkMenu).
//
fn checkItem(comptime item: Item) void {
    const label = "ziggy.menu: the item \"" ++ item.label ++ "\"";
    if (item.separator) {
        if (item.run != null or item.items != null or item.name != null or item.accelerator != null) {
            @compileError("ziggy.menu: a separator has no run, items, name or accelerator. Use ziggy.menu.separator.");
        }
        return;
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
        }
    }
    if (item.accelerator) |text| {
        _ = accelerator.parse(text) catch |err| {
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
// The menu as the JSON text the native apps read: an array of menus, each {"label", "items"}, where an item is {"label", "action",
// "accelerator"} (with no "accelerator" when it has none), {"separator": true} or a submenu {"label", "items"}. An item's "action" is
// its standard action for a `.standard` item and its name otherwise. An empty menu is "[]".
//
pub fn menuJson(comptime menu: []const Menu) []const u8 {
    return comptime made: {
        @setEvalBranchQuota(100_000);
        var text: []const u8 = "[";
        for (menu, 0..) |each, index| {
            if (index > 0) {
                text = text ++ ",";
            }
            text = text ++ "{\"label\":" ++ jsonString(each.label) ++ ",\"items\":" ++ itemsJson(each.items) ++ "}";
        }
        break :made text ++ "]";
    };
}

//
// The JSON array of the items given.
//
fn itemsJson(comptime items: []const Item) []const u8 {
    comptime {
        var text: []const u8 = "[";
        for (items, 0..) |item, index| {
            if (index > 0) {
                text = text ++ ",";
            }
            text = text ++ itemJson(item);
        }
        return text ++ "]";
    }
}

//
// The JSON object of one item.
//
fn itemJson(comptime item: Item) []const u8 {
    comptime {
        if (item.separator) {
            return "{\"separator\":true}";
        }
        if (item.items) |children| {
            return "{\"label\":" ++ jsonString(item.label) ++ ",\"items\":" ++ itemsJson(children) ++ "}";
        }
        const action = switch (item.run.?) {
            .standard => |standard| @tagName(standard),
            .zig, .ui => item.name.?,
        };
        var text: []const u8 = "{\"label\":" ++ jsonString(item.label) ++ ",\"action\":" ++ jsonString(action);
        if (item.accelerator) |shortcut| {
            text = text ++ ",\"accelerator\":" ++ jsonString(shortcut);
        }
        return text ++ "}";
    }
}

//
// The text as a JSON string, quoted and escaped by std.json.
//
fn jsonString(comptime text: []const u8) []const u8 {
    return std.fmt.comptimePrint("{f}", .{std.json.fmt(text, .{})});
}

//
// The table from the name of each `.zig` and `.ui` item, those in submenus included, to what the core does for it. Standard items and
// separators are not in it.
//
pub fn menuTargets(comptime menu: []const Menu) MenuTargets {
    return comptime made: {
        @setEvalBranchQuota(100_000);
        var entries: []const struct { []const u8, MenuTarget } = &.{};
        for (allItems(menu)) |item| {
            const run = item.run orelse continue;
            switch (run) {
                .standard => {},
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
        break :made MenuTargets.initComptime(entries);
    };
}
