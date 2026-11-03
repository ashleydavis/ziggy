//
// The keyboard shortcuts dev mode's script registers in the browser, standing in for a desktop native app: every shortcut a native app
// posts the menu-action system message for (see menuActionShortcuts in menu.zig). A standard action cannot run in dev mode, so its shortcut
// is left to the browser. The dev backend reads the list through ziggy_dev_shortcuts_json and serves it at /__ziggy/shortcuts.
//

const std = @import("std");
const shortcut_lib = @import("shortcut.zig");
const action_lib = @import("action.zig");
const menu_lib = @import("menu.zig");

//
// One shortcut as the dev script matches it against a key press, as JSON through ziggy_dev_shortcuts_json.
//
pub const DevShortcut = struct {
    // The name the dev script posts in the menu-action system message.
    action: []const u8,
    // The KeyboardEvent code of the key, which a shifted key keeps.
    code: []const u8,
    // Whether Control is held.
    ctrl: bool,
    // Whether Alt (Option on macOS) is held.
    alt: bool,
    // Whether Shift is held.
    shift: bool,
    // Whether Command on macOS, or the Windows or Super key elsewhere, is held.
    meta: bool,
};

//
// The shortcuts dev mode's script registers, made at compile time, each with the KeyboardEvent code of its key, such as "KeyH",
// "Digit5", "F11" or "ArrowUp". CmdOrCtrl is Command on macOS and Control elsewhere, as the core is built for the machine the dev
// backend and its browser run on.
//
pub fn devShortcuts(comptime menu: []const menu_lib.Menu, comptime actions: []const action_lib.Action) []const DevShortcut {
    return comptime made: {
        @setEvalBranchQuota(1_000_000);
        var entries: []const DevShortcut = &.{};
        for (menu_lib.menuActionShortcuts(menu, actions)) |menu_action_shortcut| {
            const parsed = shortcut_lib.parse(menu_action_shortcut.shortcut) catch |err| {
                @compileError("ziggy: the shortcut \"" ++ menu_action_shortcut.shortcut ++ "\", which the build checked, does not parse: " ++ @errorName(err) ++ ".");
            };
            entries = entries ++ &[_]DevShortcut{.{
                .action = menu_action_shortcut.action,
                .code = browserKeyCode(std.mem.sliceTo(&parsed.key, 0)),
                .ctrl = parsed.modifiers & shortcut_lib.modifier_ctrl != 0,
                .alt = parsed.modifiers & shortcut_lib.modifier_alt != 0,
                .shift = parsed.modifiers & shortcut_lib.modifier_shift != 0,
                .meta = parsed.modifiers & shortcut_lib.modifier_meta != 0,
            }};
        }
        const result = entries[0..entries.len].*;
        break :made &result;
    };
}

//
// The code a browser's KeyboardEvent gives for each named key the shortcut parser writes. Plus is the key that has the plus sign,
// which is Equal.
//
const named_browser_key_codes = [_]struct { []const u8, []const u8 }{
    .{ "plus", "Equal" },
    .{ "minus", "Minus" },
    .{ "equal", "Equal" },
    .{ "space", "Space" },
    .{ "enter", "Enter" },
    .{ "tab", "Tab" },
    .{ "escape", "Escape" },
    .{ "up", "ArrowUp" },
    .{ "down", "ArrowDown" },
    .{ "left", "ArrowLeft" },
    .{ "right", "ArrowRight" },
    .{ "home", "Home" },
    .{ "end", "End" },
    .{ "pageup", "PageUp" },
    .{ "pagedown", "PageDown" },
    .{ "delete", "Delete" },
    .{ "backspace", "Backspace" },
};

//
// The code a browser's KeyboardEvent gives for a key the shortcut parser wrote: "Key" and the letter in upper case, "Digit" and the
// digit, F and a function key's number, or a named key's code. The parser writes no other key.
//
fn browserKeyCode(comptime key: []const u8) []const u8 {
    if (key.len == 1 and std.ascii.isAlphabetic(key[0])) {
        return "Key" ++ [_]u8{std.ascii.toUpper(key[0])};
    }
    if (key.len == 1 and std.ascii.isDigit(key[0])) {
        return "Digit" ++ key;
    }
    if (key[0] == 'f' and std.ascii.isDigit(key[1])) {
        return "F" ++ key[1..];
    }
    for (named_browser_key_codes) |entry| {
        if (std.mem.eql(u8, entry[0], key)) {
            return entry[1];
        }
    }
    @compileError("ziggy: the shortcut key \"" ++ key ++ "\" has no KeyboardEvent code.");
}
