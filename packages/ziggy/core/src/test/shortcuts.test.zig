//
// Tests of the shortcut list a page's keydown listener matches, which the inject script runs.
//

const std = @import("std");
const ziggy = @import("ziggy");

const shortcuts_lib = ziggy.shortcuts;

//
// The actions the tests use, every kind of key the listener matches: named keys by their code, a letter, a letter with Shift, a
// digit, Plus, Minus, Equal, ? and one that keeps Ctrl.
//
const actions: []const ziggy.action.Action = &.{
    .{
        .name = "escape",
        .label = "Escape",
        .shortcut = "Escape",
    },
    .{
        .name = "down",
        .label = "Down",
        .shortcut = "Down",
    },
    .{
        .name = "enter",
        .label = "Enter",
        .shortcut = "Enter",
    },
    .{
        .name = "ask",
        .label = "Ask",
        .shortcut = "?",
    },
    .{
        .name = "j",
        .label = "J",
        .shortcut = "J",
    },
    .{
        .name = "shift-j",
        .label = "Shift J",
        .shortcut = "Shift+J",
    },
    .{
        .name = "five",
        .label = "Five",
        .shortcut = "5",
    },
    .{
        .name = "plus",
        .label = "Plus",
        .shortcut = "Plus",
    },
    .{
        .name = "minus",
        .label = "Minus",
        .shortcut = "Minus",
    },
    .{
        .name = "equal",
        .label = "Equal",
        .shortcut = "Equal",
    },
    .{
        .name = "command",
        .label = "Command",
        .shortcut = "CmdOrCtrl+Shift+O",
    },
};

//
// The entry of the action with the name, or a failure when the list has none.
//
fn entryFor(entries: []const shortcuts_lib.BrowserShortcut, name: []const u8) !shortcuts_lib.BrowserShortcut {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.action, name)) {
            return entry;
        }
    }
    return error.EntryMissing;
}

test "shortcut_list holds every shortcut of the actions, with Ctrl too" {
    const entries = comptime shortcuts_lib.shortcut_list(&.{}, actions);
    try std.testing.expectEqual(@as(usize, 11), entries.len);
    const command = try entryFor(entries, "command");
    try std.testing.expectEqualStrings("", command.code);
    try std.testing.expectEqualStrings("o", command.key);
    try std.testing.expect(command.ctrl);
    try std.testing.expect(command.shift);
    try std.testing.expect(!command.alt);
    try std.testing.expect(!command.meta);
    try std.testing.expect(!command.shiftOptional);
    try std.testing.expect(!command.standard);
    try std.testing.expect(!command.text_box);
}

test "shortcut_list marks each typing shortcut and leaves the others unmarked" {
    const entries = comptime shortcuts_lib.shortcut_list(&.{}, actions);
    try std.testing.expectEqual(@as(usize, 11), entries.len);
    // The shortcut with Ctrl is not a typing one.
    try std.testing.expect(!(try entryFor(entries, "command")).text_box);
    // Named keys are matched by their code and are typing shortcuts.
    const escape = try entryFor(entries, "escape");
    try std.testing.expectEqualStrings("Escape", escape.code);
    try std.testing.expectEqualStrings("", escape.key);
    try std.testing.expect(!escape.shiftOptional);
    try std.testing.expect(escape.text_box);
    try std.testing.expectEqualStrings("ArrowDown", (try entryFor(entries, "down")).code);
    try std.testing.expectEqualStrings("Enter", (try entryFor(entries, "enter")).code);
    // ? is matched by the character it types, which needs Shift on some layouts.
    const ask = try entryFor(entries, "ask");
    try std.testing.expectEqualStrings("", ask.code);
    try std.testing.expectEqualStrings("?", ask.key);
    try std.testing.expect(ask.shiftOptional);
    try std.testing.expect(!ask.shift);
    try std.testing.expect(ask.text_box);
    // A letter is matched by its character, and Shift is its own state.
    const j = try entryFor(entries, "j");
    try std.testing.expectEqualStrings("", j.code);
    try std.testing.expectEqualStrings("j", j.key);
    try std.testing.expect(!j.shift);
    try std.testing.expect(!j.shiftOptional);
    const shift_j = try entryFor(entries, "shift-j");
    try std.testing.expectEqualStrings("j", shift_j.key);
    try std.testing.expect(shift_j.shift);
    try std.testing.expect(!shift_j.shiftOptional);
    // A digit, Plus, Minus and Equal are matched by their character, which the layout puts on Shift or not.
    const five = try entryFor(entries, "five");
    try std.testing.expectEqualStrings("5", five.key);
    try std.testing.expect(five.shiftOptional);
    const plus = try entryFor(entries, "plus");
    try std.testing.expectEqualStrings("+", plus.key);
    try std.testing.expect(plus.shiftOptional);
    const minus = try entryFor(entries, "minus");
    try std.testing.expectEqualStrings("-", minus.key);
    try std.testing.expect(minus.shiftOptional);
    const equal = try entryFor(entries, "equal");
    try std.testing.expectEqualStrings("=", equal.key);
    try std.testing.expect(equal.shiftOptional);
}

test "key_character gives the character a key press must type" {
    try std.testing.expectEqualStrings("j", (comptime shortcuts_lib.key_character("j")).?);
    try std.testing.expectEqualStrings("5", (comptime shortcuts_lib.key_character("5")).?);
    try std.testing.expectEqualStrings("+", (comptime shortcuts_lib.key_character("plus")).?);
    try std.testing.expectEqualStrings("-", (comptime shortcuts_lib.key_character("minus")).?);
    try std.testing.expectEqualStrings("=", (comptime shortcuts_lib.key_character("equal")).?);
    try std.testing.expectEqualStrings("?", (comptime shortcuts_lib.key_character("?")).?);
    try std.testing.expect((comptime shortcuts_lib.key_character("escape")) == null);
    try std.testing.expect((comptime shortcuts_lib.key_character("down")) == null);
    try std.testing.expect((comptime shortcuts_lib.key_character("space")) == null);
    try std.testing.expect((comptime shortcuts_lib.key_character("enter")) == null);
}

test "layout_decides_shift is true for the characters a layout puts on Shift or not" {
    try std.testing.expect(comptime shortcuts_lib.layout_decides_shift("5"));
    try std.testing.expect(comptime shortcuts_lib.layout_decides_shift("plus"));
    try std.testing.expect(comptime shortcuts_lib.layout_decides_shift("minus"));
    try std.testing.expect(comptime shortcuts_lib.layout_decides_shift("equal"));
    try std.testing.expect(comptime shortcuts_lib.layout_decides_shift("?"));
    try std.testing.expect(!comptime shortcuts_lib.layout_decides_shift("j"));
    try std.testing.expect(!comptime shortcuts_lib.layout_decides_shift("escape"));
    try std.testing.expect(!comptime shortcuts_lib.layout_decides_shift("down"));
}
