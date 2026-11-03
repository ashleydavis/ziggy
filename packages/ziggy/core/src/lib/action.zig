//
// ziggy.action: the actions an app gives ziggy.core.App as `.actions`. An action is a named piece of the app's functionality that takes
// no arguments. Its handler is in the frontend, which registers it with window.ziggy.registerAction. A menu item, the action's shortcut,
// window.ziggy.runAction and the handler services' runAction all run it by its name. App checks the actions when the app is built.
//

const std = @import("std");
const shortcut_lib = @import("shortcut.zig");
const menu_lib = @import("menu.zig");

//
// One action of the app.
//
pub const Action = struct {
    // The name everything that runs the action uses. It is unique among the app's actions and is not a standard action's name.
    name: []const u8,
    // The text a menu item that runs the action shows, and the label window.ziggy.listActions gives it.
    label: []const u8,
    // The keyboard shortcut, such as "CmdOrCtrl+Shift+H", or null for none. It is written as a menu item's is.
    shortcut: ?[]const u8 = null,
};

//
// Fails the build, naming the action, when an action is wrong: an empty name, a name spelled like a standard action, an empty label, a
// shortcut that does not parse, or two actions with the same name.
//
pub fn rejectInvalidActions(comptime actions: []const Action) void {
    comptime {
        @setEvalBranchQuota(100_000);
        for (actions, 0..) |action, index| {
            if (action.name.len == 0) {
                @compileError("ziggy.action: the action \"" ++ action.label ++ "\" has an empty name.");
            }
            const label = "ziggy.action: the action \"" ++ action.name ++ "\"";
            if (std.meta.stringToEnum(menu_lib.StandardAction, action.name) != null) {
                @compileError(label ++ " has the name of a standard action.");
            }
            if (action.label.len == 0) {
                @compileError(label ++ " has an empty label.");
            }
            if (action.shortcut) |text| {
                _ = shortcut_lib.parse(text) catch |err| {
                    @compileError(label ++ " has the shortcut \"" ++ text ++ "\", which does not parse: " ++ @errorName(err) ++ ".");
                };
            }
            for (actions[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.name, action.name)) {
                    @compileError(label ++ " is declared twice.");
                }
            }
        }
    }
}

//
// A standalone action shortcut: the shortcut of an action that has no menu item, so it stands alone rather than beside a menu item. A
// desktop native app reads these through ziggy_standalone_action_shortcuts. It is laid out as ziggy.h's
// ziggy_standalone_action_shortcut, so a native app reads the array the core holds without copying it.
//
pub const StandaloneActionShortcut = extern struct {
    // The action's name, which the native app posts in the menu-action system message.
    action: [*:0]const u8,
    // The action's shortcut text, such as "CmdOrCtrl+Shift+P".
    shortcut: [*:0]const u8,
};

//
// The shortcuts a desktop native app registers apart from the menu's: one for every action that has a shortcut and no `.action` item
// on the menu. A native app posts the menu-action system message naming the action when its shortcut is pressed.
//
pub fn standaloneActionShortcuts(comptime menu: []const menu_lib.Menu, comptime actions: []const Action) []const StandaloneActionShortcut {
    return comptime made: {
        @setEvalBranchQuota(1_000_000);
        var entries: []const StandaloneActionShortcut = &.{};
        for (actions) |action| {
            const shortcut = action.shortcut orelse continue;
            if (menu_lib.hasActionMenuItem(menu, action.name)) {
                continue;
            }
            entries = entries ++ &[_]StandaloneActionShortcut{.{
                .action = menu_lib.cString(action.name),
                .shortcut = menu_lib.cString(shortcut),
            }};
        }
        const result = entries[0..entries.len].*;
        break :made &result;
    };
}
