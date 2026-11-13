//
// The keyboard shortcuts a page's `keydown` listener matches, which the inject script runs: every menu item's and action's shortcut,
// the standard items included. Each entry says how to match the key press: by the character the key types, or by its KeyboardEvent
// code, with the modifier keys it holds.
//

const std = @import("std");
const shortcut_lib = @import("shortcut.zig");
const action_lib = @import("action.zig");
const menu_lib = @import("menu.zig");

//
// One shortcut as a page's keydown listener matches it against a key press, through the list-shortcuts system message.
//
pub const BrowserShortcut = struct {
    // The name the listener posts in the menu-action system message, or in the run-action one for a standard item.
    action: []const u8,
    // Whether the action is a standard menu item, which the listener runs with run-action.
    standard: bool,
    // Whether the shortcut has no Ctrl, Alt or Cmd and is not a function key, so a focused text box keeps its key.
    text_box: bool,
    // The KeyboardEvent code of the key, which a shifted key keeps: empty for a key matched by its character.
    code: []const u8,
    // Whether Control is held.
    ctrl: bool,
    // Whether Alt (Option on macOS) is held.
    alt: bool,
    // Whether Shift is held.
    shift: bool,
    // Whether Command on macOS, or the Windows or Super key elsewhere, is held.
    meta: bool,
    // Whether Shift may be held or not, because the key's character needs Shift on some keyboard layouts and not on others.
    shiftOptional: bool,
    // The character the key press's KeyboardEvent.key must give, lower-cased, for a key that sits on a different physical key on each
    // layout: "+", "-", "=" or "?" for those keys, a letter or a digit otherwise. Empty for a key matched by its code.
    key: []const u8,
};

//
// Every shortcut the inject script runs: those of the menu's items and of the app's actions, then those of its standard items, in the
// order a menu shows them. A key that sits on a different physical key on each layout is matched by the character it types, and every
// other key by its code.
//
pub fn shortcut_list(comptime menu: []const menu_lib.Menu, comptime actions: []const action_lib.Action) []const BrowserShortcut {
    return comptime made: {
        @setEvalBranchQuota(1_000_000);
        var entries: []const BrowserShortcut = &.{};
        for (menu_lib.menuActionShortcuts(menu, actions)) |menu_action_shortcut| {
            entries = entries ++ &[_]BrowserShortcut{makeShortcut(menu_action_shortcut.action, menu_action_shortcut.shortcut, false)};
        }
        for (menu_lib.standardMenuItems(menu)) |standard_item| {
            const shortcut = standard_item.shortcut orelse continue;
            const name = std.fmt.comptimePrint("{s}", .{@tagName(standard_item.action)});
            entries = entries ++ &[_]BrowserShortcut{makeShortcut(name, shortcut, true)};
        }
        const result = entries[0..entries.len].*;
        break :made &result;
    };
}

//
// One entry of the inject script's list, from the action and shortcut text.
//
fn makeShortcut(comptime action: []const u8, comptime shortcut: []const u8, comptime standard: bool) BrowserShortcut {
    const parsed = shortcut_lib.parse(shortcut) catch |err| {
        @compileError("ziggy: the shortcut \"" ++ shortcut ++ "\", which the build checked, does not parse: " ++ @errorName(err) ++ ".");
    };
    const key = std.mem.sliceTo(&parsed.key, 0);
    std.debug.assert(key.len != 0);
    std.debug.assert(action.len != 0);
    if (parsed.modifiers & shortcut_lib.modifier_shift != 0 and layout_decides_shift(key)) {
        @compileError("ziggy: the shortcut \"" ++ shortcut ++ "\" has Shift with a key whose character the keyboard layout puts on Shift or not, so it cannot be matched on every layout. Add Ctrl, Alt or Cmd.");
    }
    const character = key_character(key);
    return .{
        .action = action,
        .standard = standard,
        .text_box = shortcut_lib.is_text_box_key(parsed),
        .code = if (character != null) "" else browserKeyCode(key),
        .ctrl = parsed.modifiers & shortcut_lib.modifier_ctrl != 0,
        .alt = parsed.modifiers & shortcut_lib.modifier_alt != 0,
        .shift = parsed.modifiers & shortcut_lib.modifier_shift != 0,
        .meta = parsed.modifiers & shortcut_lib.modifier_meta != 0,
        .shiftOptional = layout_decides_shift(key),
        .key = character orelse "",
    };
}

//
// The lower-cased character a key press's KeyboardEvent.key must give for a parsed key that sits on a different physical key on each
// layout: a letter or a digit as it is, "+", "-", "=" or "?" for Plus, Minus, Equal and ?, and null for a named key or a function key,
// which is matched by its code.
//
pub fn key_character(comptime key: []const u8) ?[]const u8 {
    std.debug.assert(key.len != 0);
    std.debug.assert(key.len <= 16);
    if (key.len == 1 and std.ascii.isAlphabetic(key[0])) {
        return key;
    }
    if (key.len == 1 and std.ascii.isDigit(key[0])) {
        return key;
    }
    if (std.mem.eql(u8, key, "?")) {
        return "?";
    }
    if (std.mem.eql(u8, key, "plus")) {
        return "+";
    }
    if (std.mem.eql(u8, key, "minus")) {
        return "-";
    }
    if (std.mem.eql(u8, key, "equal")) {
        return "=";
    }
    return null;
}

//
// Whether the keyboard layout decides whether Shift is held for the key: true for a digit, Plus, Minus, Equal and ?, whose character
// needs Shift on some layouts and not on others, and false for a letter and every named key.
//
pub fn layout_decides_shift(comptime key: []const u8) bool {
    std.debug.assert(key.len != 0);
    std.debug.assert(key.len <= 16);
    if (key.len == 1 and std.ascii.isAlphabetic(key[0])) {
        return false;
    }
    if (key.len == 1 and std.ascii.isDigit(key[0])) {
        return true;
    }
    if (std.mem.eql(u8, key, "?")) {
        return true;
    }
    if (std.mem.eql(u8, key, "plus")) {
        return true;
    }
    if (std.mem.eql(u8, key, "minus")) {
        return true;
    }
    if (std.mem.eql(u8, key, "equal")) {
        return true;
    }
    return false;
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
