const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");

const shortcut_lib = ziggy.shortcut;

fn keyText(parsed: *const shortcut_lib.Shortcut) []const u8 {
    return std.mem.sliceTo(&parsed.key, 0);
}

test "a letter with CmdOrCtrl and Shift" {
    const parsed = try shortcut_lib.parse("CmdOrCtrl+Shift+I");
    const command_or_control = if (builtin.os.tag == .macos) shortcut_lib.modifier_meta else shortcut_lib.modifier_ctrl;
    try std.testing.expectEqual(command_or_control | shortcut_lib.modifier_shift, parsed.modifiers);
    try std.testing.expectEqualStrings("i", keyText(&parsed));
}

test "a bare function key" {
    const parsed = try shortcut_lib.parse("F12");
    try std.testing.expectEqual(@as(u32, 0), parsed.modifiers);
    try std.testing.expectEqualStrings("f12", keyText(&parsed));
}

test "Ctrl, Alt and Cmd are each their own modifier, in any case" {
    const parsed = try shortcut_lib.parse("ctrl+ALT+cmd+x");
    try std.testing.expectEqual(shortcut_lib.modifier_ctrl | shortcut_lib.modifier_alt | shortcut_lib.modifier_meta, parsed.modifiers);
    try std.testing.expectEqualStrings("x", keyText(&parsed));
}

test "named keys, digits and Plus are read" {
    try std.testing.expectEqualStrings("plus", keyText(&(try shortcut_lib.parse("CmdOrCtrl+Plus"))));
    try std.testing.expectEqualStrings("minus", keyText(&(try shortcut_lib.parse("CmdOrCtrl+Minus"))));
    try std.testing.expectEqualStrings("0", keyText(&(try shortcut_lib.parse("CmdOrCtrl+0"))));
    try std.testing.expectEqualStrings("escape", keyText(&(try shortcut_lib.parse("Escape"))));
    try std.testing.expectEqualStrings("pagedown", keyText(&(try shortcut_lib.parse("Alt+PageDown"))));
}

test "bad shortcuts are errors that say what is wrong" {
    try std.testing.expectError(error.EmptyShortcut, shortcut_lib.parse(""));
    try std.testing.expectError(error.MissingKey, shortcut_lib.parse("Ctrl+Shift"));
    try std.testing.expectError(error.UnknownKey, shortcut_lib.parse("Ctrl+Banana"));
    try std.testing.expectError(error.UnknownKey, shortcut_lib.parse("Ctrl+F99"));
    try std.testing.expectError(error.UnknownKey, shortcut_lib.parse("Ctrl+A+B"));
}

test "writeDisplayText on macOS shows the modifier symbols in order, then the key" {
    var buffer: [64]u8 = undefined;
    const parsed = try shortcut_lib.parse("Ctrl+Alt+Shift+Cmd+h");
    try std.testing.expectEqualStrings("⌃⌥⇧⌘H", try shortcut_lib.writeDisplayText(&buffer, parsed, .macos));
}

test "writeDisplayText on Linux spells the modifiers, with Super for the meta key" {
    var buffer: [64]u8 = undefined;
    const parsed = try shortcut_lib.parse("Ctrl+Alt+Shift+Super+h");
    try std.testing.expectEqualStrings("Ctrl+Alt+Shift+Super+H", try shortcut_lib.writeDisplayText(&buffer, parsed, .linux));
}

test "writeDisplayText on Windows spells the modifiers, with Win for the meta key" {
    var buffer: [64]u8 = undefined;
    const parsed = try shortcut_lib.parse("Ctrl+Super+h");
    try std.testing.expectEqualStrings("Ctrl+Win+H", try shortcut_lib.writeDisplayText(&buffer, parsed, .windows));
}

test "writeDisplayText shows Plus as a plus sign and a function key as F and its number" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl++", try shortcut_lib.writeDisplayText(&buffer, try shortcut_lib.parse("Ctrl+Plus"), .linux));
    try std.testing.expectEqualStrings("⌘+", try shortcut_lib.writeDisplayText(&buffer, try shortcut_lib.parse("Cmd+Plus"), .macos));
    try std.testing.expectEqualStrings("F11", try shortcut_lib.writeDisplayText(&buffer, try shortcut_lib.parse("F11"), .windows));
    try std.testing.expectEqualStrings("Shift+PageDown", try shortcut_lib.writeDisplayText(&buffer, try shortcut_lib.parse("Shift+PageDown"), .linux));
}

test "writeDisplayText fails when the buffer is too small" {
    var buffer: [4]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, shortcut_lib.writeDisplayText(&buffer, try shortcut_lib.parse("Ctrl+Alt+Shift+h"), .linux));
}
