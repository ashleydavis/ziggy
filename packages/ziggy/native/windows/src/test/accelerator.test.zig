const std = @import("std");
const accelerator = @import("../lib/accelerator.zig");

test "a letter is its upper case virtual key" {
    const binding = accelerator.bindingFor(accelerator.modifier_control | accelerator.modifier_shift, "i").?;
    try std.testing.expectEqual(@as(u32, 'I'), binding.virtual_key);
    try std.testing.expectEqual(accelerator.modifier_control | accelerator.modifier_shift, binding.modifiers);
}

test "a digit has the keypad digit as its alternate" {
    const binding = accelerator.bindingFor(accelerator.modifier_control, "0").?;
    try std.testing.expectEqual(@as(u32, '0'), binding.virtual_key);
    try std.testing.expectEqual(@as(u32, 0x60), binding.alternate_virtual_key);
}

test "function keys count up from F1" {
    try std.testing.expectEqual(@as(u32, 0x70), accelerator.bindingFor(0, "f1").?.virtual_key);
    try std.testing.expectEqual(@as(u32, 0x7B), accelerator.bindingFor(0, "f12").?.virtual_key);
    try std.testing.expectEqual(@as(?accelerator.Binding, null), accelerator.bindingFor(0, "f25"));
    try std.testing.expectEqual(@as(?accelerator.Binding, null), accelerator.bindingFor(0, "f0"));
}

test "named keys" {
    try std.testing.expectEqual(@as(u32, 0xBD), accelerator.bindingFor(0, "minus").?.virtual_key);
    try std.testing.expectEqual(@as(u32, 0x1B), accelerator.bindingFor(0, "escape").?.virtual_key);
    try std.testing.expectEqual(@as(?accelerator.Binding, null), accelerator.bindingFor(0, "nonsense"));
}

test "a key press must have exactly the binding's modifiers" {
    const binding = accelerator.bindingFor(accelerator.modifier_control, "r").?;
    try std.testing.expect(accelerator.matches(binding, 'R', accelerator.modifier_control));
    try std.testing.expect(!accelerator.matches(binding, 'R', accelerator.modifier_control | accelerator.modifier_shift));
    try std.testing.expect(!accelerator.matches(binding, 'R', 0));
    try std.testing.expect(!accelerator.matches(binding, 'T', accelerator.modifier_control));
}

test "plus matches with or without Shift and on the keypad" {
    const binding = accelerator.bindingFor(accelerator.modifier_control, "plus").?;
    try std.testing.expect(accelerator.matches(binding, 0xBB, accelerator.modifier_control));
    try std.testing.expect(accelerator.matches(binding, 0xBB, accelerator.modifier_control | accelerator.modifier_shift));
    try std.testing.expect(accelerator.matches(binding, 0x6B, accelerator.modifier_control));
    try std.testing.expect(!accelerator.matches(binding, 0xBB, accelerator.modifier_control | accelerator.modifier_alt));
}

test "a Plus shortcut runs on the key that types = in the layout" {
    const binding = accelerator.bindingFor(accelerator.modifier_control, "plus").?;
    // A US layout types = with the key VK_OEM_PLUS, with Shift or without.
    try std.testing.expect(accelerator.matches_layout_equal(binding, 0x00BB, 0xBB, accelerator.modifier_control));
    try std.testing.expect(accelerator.matches_layout_equal(binding, 0x00BB, 0xBB, accelerator.modifier_control | accelerator.modifier_shift));
    // A German layout types = with Shift and the 0 key, so Ctrl+0 alone is Actual Size's key press and runs nothing.
    try std.testing.expect(accelerator.matches_layout_equal(binding, 0x0130, 0x30, accelerator.modifier_control | accelerator.modifier_shift));
    try std.testing.expect(!accelerator.matches_layout_equal(binding, 0x0130, 0x30, accelerator.modifier_control));
    // A layout with no key for =, or one that needs Ctrl or Alt, gets no match.
    try std.testing.expect(!accelerator.matches_layout_equal(binding, -1, 0xBB, accelerator.modifier_control));
    try std.testing.expect(!accelerator.matches_layout_equal(binding, 0x0230, 0x30, accelerator.modifier_control));
    try std.testing.expect(!accelerator.matches_layout_equal(binding, 0x0430, 0x30, accelerator.modifier_control));
    // A binding that is not a Plus one gets no layout = match.
    const equal = accelerator.bindingFor(accelerator.modifier_control, "equal").?;
    try std.testing.expect(!accelerator.matches_layout_equal(equal, 0x00BB, 0xBB, accelerator.modifier_control));
    const zero = accelerator.bindingFor(accelerator.modifier_control, "0").?;
    try std.testing.expect(!accelerator.matches_layout_equal(zero, 0x00BB, 0xBB, accelerator.modifier_control));
}

test "the layout equal key gives its virtual key and whether it needs Shift" {
    try std.testing.expectEqual(@as(?accelerator.LayoutEqualKey, .{ .virtual_key = 0xBB, .needs_shift = false }), accelerator.layout_equal_key(0x00BB));
    try std.testing.expectEqual(@as(?accelerator.LayoutEqualKey, .{ .virtual_key = 0x30, .needs_shift = true }), accelerator.layout_equal_key(0x0130));
    try std.testing.expectEqual(@as(?accelerator.LayoutEqualKey, null), accelerator.layout_equal_key(-1));
    try std.testing.expectEqual(@as(?accelerator.LayoutEqualKey, null), accelerator.layout_equal_key(0x0230));
}

test "shortcut text is written the Windows way" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Shift+I", try accelerator.formatShortcut(&buffer, accelerator.modifier_control | accelerator.modifier_shift, "i"));
    try std.testing.expectEqualStrings("F11", try accelerator.formatShortcut(&buffer, 0, "f11"));
    try std.testing.expectEqualStrings("Ctrl++", try accelerator.formatShortcut(&buffer, accelerator.modifier_control, "plus"));
    try std.testing.expectEqualStrings("Ctrl+0", try accelerator.formatShortcut(&buffer, accelerator.modifier_control, "0"));
    try std.testing.expectEqualStrings("Ctrl+Alt+Del", try accelerator.formatShortcut(&buffer, accelerator.modifier_control | accelerator.modifier_alt, "delete"));
    try std.testing.expectError(error.UnknownKey, accelerator.formatShortcut(&buffer, 0, "nonsense"));
}
