//
// The events the Windows native app sends the web view for the remote control's press-key command: the Input.dispatchKeyEvent
// parameters of a key press, built from the key the core named. It is used only by that test hook.
//

const std = @import("std");
const accelerator = @import("accelerator.zig");

//
// The type values Input.dispatchKeyEvent takes.
//
pub const KeyEventKind = enum {
    // The key going down, before Chromium turns it into text.
    raw_key_down,
    // The text the key types.
    char,
    // The key going up.
    key_up,
};

//
// The KeyboardEvent.key, code and text of a named key.
//
const NamedKeyDom = struct {
    // The name the core uses.
    name: []const u8,
    // The KeyboardEvent.key.
    dom_key: []const u8,
    // The KeyboardEvent.code.
    dom_code: []const u8,
    // The text the key types, or empty for none.
    text: []const u8,
};

//
// The DOM names of every named key the core's parser writes.
//
const named_key_dom = [_]NamedKeyDom{
    .{ .name = "plus", .dom_key = "+", .dom_code = "Equal", .text = "+" },
    .{ .name = "equal", .dom_key = "=", .dom_code = "Equal", .text = "=" },
    .{ .name = "minus", .dom_key = "-", .dom_code = "Minus", .text = "-" },
    .{ .name = "space", .dom_key = " ", .dom_code = "Space", .text = " " },
    .{ .name = "enter", .dom_key = "Enter", .dom_code = "Enter", .text = "\r" },
    .{ .name = "tab", .dom_key = "Tab", .dom_code = "Tab", .text = "" },
    .{ .name = "escape", .dom_key = "Escape", .dom_code = "Escape", .text = "" },
    .{ .name = "up", .dom_key = "ArrowUp", .dom_code = "ArrowUp", .text = "" },
    .{ .name = "down", .dom_key = "ArrowDown", .dom_code = "ArrowDown", .text = "" },
    .{ .name = "left", .dom_key = "ArrowLeft", .dom_code = "ArrowLeft", .text = "" },
    .{ .name = "right", .dom_key = "ArrowRight", .dom_code = "ArrowRight", .text = "" },
    .{ .name = "home", .dom_key = "Home", .dom_code = "Home", .text = "" },
    .{ .name = "end", .dom_key = "End", .dom_code = "End", .text = "" },
    .{ .name = "pageup", .dom_key = "PageUp", .dom_code = "PageUp", .text = "" },
    .{ .name = "pagedown", .dom_key = "PageDown", .dom_code = "PageDown", .text = "" },
    .{ .name = "delete", .dom_key = "Delete", .dom_code = "Delete", .text = "" },
    .{ .name = "backspace", .dom_key = "Backspace", .dom_code = "Backspace", .text = "" },
};

//
// The named key's DOM names, or null for a letter, a digit or a function key.
//
fn findNamedKey(key_name: []const u8) ?NamedKeyDom {
    for (named_key_dom) |named| {
        if (std.mem.eql(u8, named.name, key_name)) {
            return named;
        }
    }
    return null;
}

//
// The function key number (1 to 24) when the name is one, or null.
//
fn functionKeyNumber(key_name: []const u8) ?u32 {
    if (key_name.len < 2 or key_name[0] != 'f') {
        return null;
    }
    const number = std.fmt.parseInt(u32, key_name[1..], 10) catch {
        return null;
    };
    if (number < 1 or number > 24) {
        return null;
    }
    return number;
}

//
// Whether a press of the key sends Windows a WM_CHAR: the key types text and Control, Alt and the Windows key are not held.
//
pub fn has_char_event(modifiers: u32, key_name: []const u8) bool {
    if (modifiers & (accelerator.modifier_control | accelerator.modifier_alt | accelerator.modifier_windows) != 0) {
        return false;
    }
    if (key_name.len == 1) {
        return true;
    }
    if (findNamedKey(key_name)) |named| {
        return named.text.len > 0;
    }
    return false;
}

//
// Writes text as a JSON string, with its quotes, backslashes and control characters escaped.
//
fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

//
// Writes the parameters of Input.dispatchKeyEvent as the JSON text of an object: the kind, the modifiers as DevTools bits, the
// virtual key code, the KeyboardEvent.key and code, and for a char event the text the key types. An unknown key name is
// error.UnknownKey, and a buffer too small is the writer's error.
//
pub fn key_event_params(buffer: []u8, kind: KeyEventKind, binding: accelerator.Binding, key_name: []const u8, layout_shift: bool) ![]const u8 {
    var modifiers = binding.modifiers;
    if (layout_shift) {
        modifiers |= accelerator.modifier_shift;
    }
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("{\"type\":\"");
    try writer.writeAll(switch (kind) {
        .raw_key_down => "rawKeyDown",
        .char => "char",
        .key_up => "keyUp",
    });
    var devtools: u32 = 0;
    if (modifiers & accelerator.modifier_alt != 0) {
        devtools |= 1;
    }
    if (modifiers & accelerator.modifier_control != 0) {
        devtools |= 2;
    }
    if (modifiers & accelerator.modifier_windows != 0) {
        devtools |= 4;
    }
    if (modifiers & accelerator.modifier_shift != 0) {
        devtools |= 8;
    }
    try writer.print("\",\"modifiers\":{d},\"windowsVirtualKeyCode\":{d}", .{ devtools, binding.virtual_key });

    var text: []const u8 = "";
    if (key_name.len == 1 and std.ascii.isAlphabetic(key_name[0])) {
        const upper = std.ascii.toUpper(key_name[0]);
        const shifted = modifiers & accelerator.modifier_shift != 0;
        const character = if (shifted) upper else std.ascii.toLower(key_name[0]);
        try writer.writeAll(",\"key\":");
        try writeJsonString(&writer, &[_]u8{character});
        try writer.writeAll(",\"code\":\"Key");
        try writer.writeByte(upper);
        try writer.writeByte('"');
        text = &[_]u8{character};
    }
    else if (key_name.len == 1 and std.ascii.isDigit(key_name[0])) {
        try writer.writeAll(",\"key\":");
        try writeJsonString(&writer, key_name);
        try writer.writeAll(",\"code\":\"Digit");
        try writer.writeByte(key_name[0]);
        try writer.writeByte('"');
        text = key_name;
    }
    else if (key_name.len == 1) {
        // A character with no code of its own, such as ?.
        try writer.writeAll(",\"key\":");
        try writeJsonString(&writer, key_name);
        try writer.writeAll(",\"code\":\"\"");
        text = key_name;
    }
    else if (functionKeyNumber(key_name)) |number| {
        var function_buffer: [4]u8 = undefined;
        const function_text = std.fmt.bufPrint(&function_buffer, "F{d}", .{number}) catch unreachable;
        try writer.writeAll(",\"key\":");
        try writeJsonString(&writer, function_text);
        try writer.writeAll(",\"code\":");
        try writeJsonString(&writer, function_text);
    }
    else if (findNamedKey(key_name)) |named| {
        try writer.writeAll(",\"key\":");
        try writeJsonString(&writer, named.dom_key);
        try writer.writeAll(",\"code\":");
        try writeJsonString(&writer, named.dom_code);
        text = named.text;
    }
    else {
        return error.UnknownKey;
    }
    if (kind == .char) {
        try writer.writeAll(",\"text\":");
        try writeJsonString(&writer, text);
    }
    try writer.writeByte('}');
    return writer.buffered();
}
