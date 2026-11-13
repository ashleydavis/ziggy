const std = @import("std");
const menu_keys = @import("../lib/menu-keys.zig");

test "a letter or digit keeps its name" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("i", try menu_keys.gdkKeyName(&buffer, "i"));
    try std.testing.expectEqualStrings("0", try menu_keys.gdkKeyName(&buffer, "0"));
}

test "a function key gets a capital F" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("F12", try menu_keys.gdkKeyName(&buffer, "f12"));
    try std.testing.expectEqualStrings("F1", try menu_keys.gdkKeyName(&buffer, "f1"));
}

test "named keys become the names GDK knows" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("plus", try menu_keys.gdkKeyName(&buffer, "plus"));
    try std.testing.expectEqualStrings("Return", try menu_keys.gdkKeyName(&buffer, "enter"));
    try std.testing.expectEqualStrings("Page_Down", try menu_keys.gdkKeyName(&buffer, "pagedown"));
    try std.testing.expectEqualStrings("BackSpace", try menu_keys.gdkKeyName(&buffer, "backspace"));
}

test "an unknown key is an error" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectError(error.UnknownKey, menu_keys.gdkKeyName(&buffer, "banana"));
}

test "a menu item shows its label, a tab and its shortcut" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Open Database...\tCtrl+O", try menu_keys.menuLabel(&buffer, "Open Database...", "Ctrl+O"));
    // A buffer too small for the text is an error, not a cut label.
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, menu_keys.menuLabel(&small, "Open", "Ctrl+O"));
}

test "the masks before a modifier are OR'd" {
    const control = menu_keys.gdk_control_mask;
    const shift = menu_keys.gdk_shift_mask;
    try std.testing.expectEqual(@as(c_uint, 0), menu_keys.modifier_mask_before(&.{ control, shift }, 0));
    try std.testing.expectEqual(control, menu_keys.modifier_mask_before(&.{ control, shift }, 1));
    try std.testing.expectEqual(control | shift, menu_keys.modifier_mask_before(&.{ control, shift }, 2));
}

test "? is the keysym question" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("question", try menu_keys.gdkKeyName(&buffer, "?"));
}

test "the modifier bits become GDK's flags" {
    try std.testing.expectEqual(@as(c_uint, 0), menu_keys.gdkModifiers(0));
    try std.testing.expectEqual(@as(c_uint, 4), menu_keys.gdkModifiers(1));
    try std.testing.expectEqual(@as(c_uint, 4 | 1), menu_keys.gdkModifiers(1 | 2));
    try std.testing.expectEqual(@as(c_uint, 8), menu_keys.gdkModifiers(4));
    try std.testing.expectEqual(@as(c_uint, 1 << 26), menu_keys.gdkModifiers(8));
}

test "the modifier names come in the order a keyboard presses them" {
    try std.testing.expectEqual(@as(u32, 0), menu_keys.gdk_modifier_key_names(0).count);
    // The core's bits are Ctrl 1, Shift 2, Alt 4 and Meta 8, and a keyboard presses them in that order.
    const all = menu_keys.gdk_modifier_key_names(1 | 2 | 4 | 8);
    try std.testing.expectEqual(@as(u32, 4), all.count);
    try std.testing.expectEqualStrings("Control_L", all.names[0]);
    try std.testing.expectEqualStrings("Shift_L", all.names[1]);
    try std.testing.expectEqualStrings("Alt_L", all.names[2]);
    try std.testing.expectEqualStrings("Super_L", all.names[3]);
    const shift_and_meta = menu_keys.gdk_modifier_key_names(2 | 8);
    try std.testing.expectEqual(@as(u32, 2), shift_and_meta.count);
    try std.testing.expectEqualStrings("Shift_L", shift_and_meta.names[0]);
    try std.testing.expectEqualStrings("Super_L", shift_and_meta.names[1]);
}

test "each modifier name has its GDK mask" {
    try std.testing.expectEqual(menu_keys.gdk_control_mask, try menu_keys.gdk_modifier_mask("Control_L"));
    try std.testing.expectEqual(menu_keys.gdk_shift_mask, try menu_keys.gdk_modifier_mask("Shift_L"));
    try std.testing.expectEqual(menu_keys.gdk_alt_mask, try menu_keys.gdk_modifier_mask("Alt_L"));
    try std.testing.expectEqual(menu_keys.gdk_super_mask, try menu_keys.gdk_modifier_mask("Super_L"));
    try std.testing.expectError(error.UnknownModifierKey, menu_keys.gdk_modifier_mask("Control_R"));
}

test "the lowest level key of group 0 is chosen" {
    try std.testing.expectEqual(@as(?menu_keys.KeyEntry, null), menu_keys.lowest_level_key(&.{}));
    // A layout may put a key in another group: only group 0 counts.
    try std.testing.expectEqual(@as(?menu_keys.KeyEntry, null), menu_keys.lowest_level_key(&.{
        .{ .keycode = 10, .group = 1, .level = 0 },
    }));
    // The level 0 key wins over a level 1 key, whatever their order.
    const chosen = menu_keys.lowest_level_key(&.{
        .{ .keycode = 20, .group = 0, .level = 1 },
        .{ .keycode = 10, .group = 0, .level = 0 },
    });
    try std.testing.expectEqual(@as(?menu_keys.KeyEntry, .{ .keycode = 10, .group = 0, .level = 0 }), chosen);
    // Two keys at the same level: the first one.
    const first = menu_keys.lowest_level_key(&.{
        .{ .keycode = 11, .group = 0, .level = 0 },
        .{ .keycode = 12, .group = 0, .level = 0 },
    });
    try std.testing.expectEqual(@as(?menu_keys.KeyEntry, .{ .keycode = 11, .group = 0, .level = 0 }), first);
}

test "a key press holds each modifier in order and lets go in reverse" {
    const control = menu_keys.gdk_control_mask;
    const shift = menu_keys.gdk_shift_mask;
    var buffer: [10]menu_keys.KeyPressStep = undefined;
    const steps = menu_keys.key_press_steps(&buffer, &.{ control, shift });
    try std.testing.expectEqual(@as(usize, 6), steps.len);
    try std.testing.expectEqual(true, !steps[0].is_release);
    try std.testing.expectEqual(@as(?u32, 0), steps[0].modifier_index);
    try std.testing.expectEqual(@as(c_uint, 0), steps[0].state);
    try std.testing.expectEqual(false, steps[1].is_release);
    try std.testing.expectEqual(@as(?u32, 1), steps[1].modifier_index);
    try std.testing.expectEqual(control, steps[1].state);
    // The key's own press and release carry every modifier.
    try std.testing.expectEqual(false, steps[2].is_release);
    try std.testing.expectEqual(@as(?u32, null), steps[2].modifier_index);
    try std.testing.expectEqual(control | shift, steps[2].state);
    try std.testing.expectEqual(true, steps[3].is_release);
    try std.testing.expectEqual(control | shift, steps[3].state);
    // The releases come back in reverse, each carrying the modifiers still down, itself among them.
    try std.testing.expectEqual(true, steps[4].is_release);
    try std.testing.expectEqual(@as(?u32, 1), steps[4].modifier_index);
    try std.testing.expectEqual(control | shift, steps[4].state);
    try std.testing.expectEqual(true, steps[5].is_release);
    try std.testing.expectEqual(@as(?u32, 0), steps[5].modifier_index);
    try std.testing.expectEqual(control, steps[5].state);
    // No modifier: just the key, pressed and released.
    const plain = menu_keys.key_press_steps(&buffer, &.{});
    try std.testing.expectEqual(@as(usize, 2), plain.len);
    try std.testing.expectEqual(@as(?u32, null), plain[0].modifier_index);
    try std.testing.expectEqual(false, plain[0].is_release);
    try std.testing.expectEqual(true, plain[1].is_release);
    // Four modifiers fill the buffer exactly.
    const all = menu_keys.key_press_steps(&buffer, &.{ control, shift, menu_keys.gdk_alt_mask, menu_keys.gdk_super_mask });
    try std.testing.expectEqual(@as(usize, 10), all.len);
}
