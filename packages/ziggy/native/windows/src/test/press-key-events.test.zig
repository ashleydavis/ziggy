const std = @import("std");
const accelerator = @import("../lib/accelerator.zig");
const press_key_events = @import("../lib/press-key-events.zig");

test "key_event_params writes the DevTools protocol's key event" {
    var buffer: [256]u8 = undefined;
    const plus = accelerator.bindingFor(accelerator.modifier_control, "plus").?;
    try std.testing.expectEqualStrings(
        "{\"type\":\"rawKeyDown\",\"modifiers\":10,\"windowsVirtualKeyCode\":187,\"key\":\"+\",\"code\":\"Equal\"}",
        try press_key_events.key_event_params(&buffer, .raw_key_down, plus, "plus", true),
    );
    const up = accelerator.bindingFor(0, "up").?;
    try std.testing.expectEqualStrings(
        "{\"type\":\"rawKeyDown\",\"modifiers\":0,\"windowsVirtualKeyCode\":38,\"key\":\"ArrowUp\",\"code\":\"ArrowUp\"}",
        try press_key_events.key_event_params(&buffer, .raw_key_down, up, "up", false),
    );
    const alt_h = accelerator.bindingFor(accelerator.modifier_alt, "h").?;
    try std.testing.expectEqualStrings(
        "{\"type\":\"rawKeyDown\",\"modifiers\":1,\"windowsVirtualKeyCode\":72,\"key\":\"h\",\"code\":\"KeyH\"}",
        try press_key_events.key_event_params(&buffer, .raw_key_down, alt_h, "h", false),
    );
    const windows_h = accelerator.bindingFor(accelerator.modifier_windows, "h").?;
    try std.testing.expectEqualStrings(
        "{\"type\":\"rawKeyDown\",\"modifiers\":4,\"windowsVirtualKeyCode\":72,\"key\":\"h\",\"code\":\"KeyH\"}",
        try press_key_events.key_event_params(&buffer, .raw_key_down, windows_h, "h", false),
    );
    const enter = accelerator.bindingFor(0, "enter").?;
    try std.testing.expectEqualStrings(
        "{\"type\":\"char\",\"modifiers\":0,\"windowsVirtualKeyCode\":13,\"key\":\"Enter\",\"code\":\"Enter\",\"text\":\"\\r\"}",
        try press_key_events.key_event_params(&buffer, .char, enter, "enter", false),
    );
    try std.testing.expectEqualStrings(
        "{\"type\":\"char\",\"modifiers\":10,\"windowsVirtualKeyCode\":187,\"key\":\"+\",\"code\":\"Equal\",\"text\":\"+\"}",
        try press_key_events.key_event_params(&buffer, .char, plus, "plus", true),
    );
    const space = accelerator.bindingFor(0, "space").?;
    try std.testing.expectEqualStrings(
        "{\"type\":\"char\",\"modifiers\":0,\"windowsVirtualKeyCode\":32,\"key\":\" \",\"code\":\"Space\",\"text\":\" \"}",
        try press_key_events.key_event_params(&buffer, .char, space, "space", false),
    );
    const shift_h = accelerator.bindingFor(accelerator.modifier_shift, "h").?;
    try std.testing.expectEqualStrings(
        "{\"type\":\"char\",\"modifiers\":8,\"windowsVirtualKeyCode\":72,\"key\":\"H\",\"code\":\"KeyH\",\"text\":\"H\"}",
        try press_key_events.key_event_params(&buffer, .char, shift_h, "h", false),
    );
    const five = accelerator.bindingFor(0, "5").?;
    try std.testing.expectEqualStrings(
        "{\"type\":\"keyUp\",\"modifiers\":0,\"windowsVirtualKeyCode\":53,\"key\":\"5\",\"code\":\"Digit5\"}",
        try press_key_events.key_event_params(&buffer, .key_up, five, "5", false),
    );
    const f5 = accelerator.bindingFor(0, "f5").?;
    try std.testing.expectEqualStrings(
        "{\"type\":\"keyUp\",\"modifiers\":0,\"windowsVirtualKeyCode\":116,\"key\":\"F5\",\"code\":\"F5\"}",
        try press_key_events.key_event_params(&buffer, .key_up, f5, "f5", false),
    );
    try std.testing.expectError(error.UnknownKey, press_key_events.key_event_params(&buffer, .key_up, f5, "nonsense", false));
    var small: [8]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, press_key_events.key_event_params(&small, .key_up, f5, "f5", false));
}

test "has_char_event tells which key presses type text" {
    try std.testing.expect(press_key_events.has_char_event(0, "h"));
    try std.testing.expect(press_key_events.has_char_event(0, "5"));
    try std.testing.expect(press_key_events.has_char_event(0, "plus"));
    try std.testing.expect(press_key_events.has_char_event(0, "space"));
    try std.testing.expect(press_key_events.has_char_event(0, "enter"));
    try std.testing.expect(press_key_events.has_char_event(accelerator.modifier_shift, "h"));
    try std.testing.expect(!press_key_events.has_char_event(accelerator.modifier_control, "h"));
    try std.testing.expect(!press_key_events.has_char_event(accelerator.modifier_alt, "h"));
    try std.testing.expect(!press_key_events.has_char_event(accelerator.modifier_windows, "h"));
    try std.testing.expect(!press_key_events.has_char_event(0, "up"));
    try std.testing.expect(!press_key_events.has_char_event(0, "escape"));
    try std.testing.expect(!press_key_events.has_char_event(0, "tab"));
    try std.testing.expect(!press_key_events.has_char_event(0, "f5"));
}
