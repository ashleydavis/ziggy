//
// Parses the keyboard shortcut text a menu item carries, such as "CmdOrCtrl+Shift+I", into modifiers and a key name, so every
// native app reads shortcuts the same way and each only has to turn the result into its own platform's form.
//
// A shortcut is modifiers and one key joined by plus signs. The modifiers are CmdOrCtrl (Command on MacOS and Control
// everywhere else), Cmd, Ctrl, Alt (also Option) and Shift. The key is a letter, a digit, a function key such as F12, `?`, or one
// of Plus, Minus, Equal, Space, Enter, Tab, Escape, Up, Down, Left, Right, Home, End, PageUp, PageDown, Delete and Backspace.
//

const std = @import("std");
const builtin = @import("builtin");

//
// The modifier bits of a parsed shortcut.
//
pub const modifier_ctrl: u32 = 1;
pub const modifier_shift: u32 = 2;
pub const modifier_alt: u32 = 4;
// Command on MacOS, and the Windows or Super key elsewhere.
pub const modifier_meta: u32 = 8;

//
// The longest key name a shortcut can carry.
//
pub const key_capacity: usize = 16;

//
// A parsed shortcut.
//
pub const Shortcut = extern struct {
    // Which modifier keys are held, as a mix of the modifier bits.
    modifiers: u32,
    // The key's name, NUL terminated: a lower case letter or digit, a function key name, `?`, or one of the names listed above. `?`
    // takes no modifiers, because a native app matches a fixed key while the key that types `?` changes with the keyboard layout.
    key: [key_capacity]u8,
};

//
// Why a shortcut could not be read.
//
pub const ParseError = error{
    EmptyShortcut,
    UnknownModifier,
    MissingKey,
    UnknownKey,
    // `?` cannot be matched with a modifier: the key that types it changes with the keyboard layout, so only a native app's fixed
    // key could match it.
    ModifierWithQuestionMark,
};

//
// Parses shortcut text. CmdOrCtrl becomes Command on MacOS and Control elsewhere, decided by what the core was built for.
//
pub fn parse(text: []const u8) ParseError!Shortcut {
    if (text.len == 0) {
        return error.EmptyShortcut;
    }
    var result = Shortcut{
        .modifiers = 0,
        .key = std.mem.zeroes([key_capacity]u8),
    };
    var key_text: ?[]const u8 = null;
    var parts = std.mem.splitScalar(u8, text, '+');
    while (parts.next()) |part| {
        if (key_text != null) {
            // Anything after the key means the key itself was a modifier name or a plus sign that was not spelled Plus.
            return error.UnknownKey;
        }
        if (std.ascii.eqlIgnoreCase(part, "CmdOrCtrl") or std.ascii.eqlIgnoreCase(part, "CommandOrControl")) {
            result.modifiers |= if (builtin.os.tag == .macos) modifier_meta else modifier_ctrl;
        }
        else if (std.ascii.eqlIgnoreCase(part, "Cmd") or std.ascii.eqlIgnoreCase(part, "Command") or std.ascii.eqlIgnoreCase(part, "Super")) {
            result.modifiers |= modifier_meta;
        }
        else if (std.ascii.eqlIgnoreCase(part, "Ctrl") or std.ascii.eqlIgnoreCase(part, "Control")) {
            result.modifiers |= modifier_ctrl;
        }
        else if (std.ascii.eqlIgnoreCase(part, "Alt") or std.ascii.eqlIgnoreCase(part, "Option")) {
            result.modifiers |= modifier_alt;
        }
        else if (std.ascii.eqlIgnoreCase(part, "Shift")) {
            result.modifiers |= modifier_shift;
        }
        else {
            key_text = part;
        }
    }
    const key = key_text orelse {
        return error.MissingKey;
    };
    try writeKey(&result.key, key);
    if (std.mem.eql(u8, std.mem.sliceTo(&result.key, 0), "?") and result.modifiers != 0) {
        return error.ModifierWithQuestionMark;
    }
    return result;
}

const named_keys = [_][]const u8{
    "plus", "minus", "equal", "space", "enter", "tab", "escape", "up", "down", "left", "right", "home", "end", "pageup", "pagedown", "delete", "backspace",
};

fn writeKey(destination: *[key_capacity]u8, key: []const u8) ParseError!void {
    if (key.len == 0) {
        return error.MissingKey;
    }
    if (key.len == 1 and std.ascii.isAlphanumeric(key[0])) {
        destination[0] = std.ascii.toLower(key[0]);
        return;
    }
    if (key.len == 1 and key[0] == '?') {
        destination[0] = '?';
        return;
    }
    if ((key[0] == 'F' or key[0] == 'f') and key.len >= 2 and key.len <= 3) {
        const number = std.fmt.parseInt(u8, key[1..], 10) catch {
            return error.UnknownKey;
        };
        if (number >= 1 and number <= 24) {
            destination[0] = 'f';
            @memcpy(destination[1 .. key.len], key[1..]);
            return;
        }
        return error.UnknownKey;
    }
    for (named_keys) |name| {
        if (std.ascii.eqlIgnoreCase(key, name)) {
            for (name, 0..) |character, index| {
                destination[index] = character;
            }
            return;
        }
    }
    return error.UnknownKey;
}

//
// How each key name parse writes is shown to the user, for the names that are not a letter, a digit or a function key.
//
const key_display_names = [_]struct { []const u8, []const u8 }{
    .{ "plus", "+" },
    .{ "minus", "-" },
    .{ "equal", "=" },
    .{ "space", "Space" },
    .{ "enter", "Enter" },
    .{ "tab", "Tab" },
    .{ "escape", "Escape" },
    .{ "up", "Up" },
    .{ "down", "Down" },
    .{ "left", "Left" },
    .{ "right", "Right" },
    .{ "home", "Home" },
    .{ "end", "End" },
    .{ "pageup", "PageUp" },
    .{ "pagedown", "PageDown" },
    .{ "delete", "Delete" },
    .{ "backspace", "Backspace" },
};

//
// Writes a parsed shortcut into the buffer as the platform shows it to the user, and returns the written text: the symbols ⌃⌥⇧⌘ then the key on
// macOS, and Ctrl+, Alt+, Shift+ and Super+ (Win+ on Windows) then the key elsewhere. A letter is shown in upper case, a function key
// as F and its number, and Plus, Minus and Equal as the sign. Fails with error.WriteFailed when the buffer is too small.
//
pub fn writeDisplayText(buffer: []u8, parsed: Shortcut, os_tag: std.Target.Os.Tag) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    if (os_tag == .macos) {
        if (parsed.modifiers & modifier_ctrl != 0) {
            try writer.writeAll("⌃");
        }
        if (parsed.modifiers & modifier_alt != 0) {
            try writer.writeAll("⌥");
        }
        if (parsed.modifiers & modifier_shift != 0) {
            try writer.writeAll("⇧");
        }
        if (parsed.modifiers & modifier_meta != 0) {
            try writer.writeAll("⌘");
        }
    }
    else {
        if (parsed.modifiers & modifier_ctrl != 0) {
            try writer.writeAll("Ctrl+");
        }
        if (parsed.modifiers & modifier_alt != 0) {
            try writer.writeAll("Alt+");
        }
        if (parsed.modifiers & modifier_shift != 0) {
            try writer.writeAll("Shift+");
        }
        if (parsed.modifiers & modifier_meta != 0) {
            try writer.writeAll(if (os_tag == .windows) "Win+" else "Super+");
        }
    }
    const key = std.mem.sliceTo(&parsed.key, 0);
    if (key.len == 1) {
        try writer.writeByte(std.ascii.toUpper(key[0]));
    }
    else if (key[0] == 'f' and std.ascii.isDigit(key[1])) {
        try writer.writeByte('F');
        try writer.writeAll(key[1..]);
    }
    else {
        for (key_display_names) |entry| {
            if (std.mem.eql(u8, entry[0], key)) {
                try writer.writeAll(entry[1]);
                break;
            }
        }
        else {
            try writer.writeAll(key);
        }
    }
    return writer.buffered();
}

//
// Whether the shortcut is a typing shortcut: one with no Ctrl, Alt or Cmd whose key is not a function key. A focused text box types,
// moves its cursor or extends its selection with every such key, so the frontend runs these and only while no text box has the focus.
// A parsed `?` has no modifiers and is not a function key, so it is a typing shortcut.
//
pub fn is_text_box_key(parsed: Shortcut) bool {
    const key = std.mem.sliceTo(&parsed.key, 0);
    std.debug.assert(key.len != 0);
    std.debug.assert(parsed.modifiers & ~(modifier_ctrl | modifier_shift | modifier_alt | modifier_meta) == 0);
    if (parsed.modifiers & (modifier_ctrl | modifier_alt | modifier_meta) != 0) {
        return false;
    }
    if (key[0] == 'f' and key.len >= 2 and std.ascii.isDigit(key[1])) {
        return false;
    }
    return true;
}

//
// Whether two shortcuts are the same key press: the same modifiers and the same key, with Plus and Equal counting as one key because
// a Plus shortcut also runs on `=`.
//
pub fn is_same_key_press(first: Shortcut, second: Shortcut) bool {
    const first_key = std.mem.sliceTo(&first.key, 0);
    const second_key = std.mem.sliceTo(&second.key, 0);
    std.debug.assert(first_key.len != 0);
    std.debug.assert(second_key.len != 0);
    std.debug.assert(first.modifiers & ~(modifier_ctrl | modifier_shift | modifier_alt | modifier_meta) == 0);
    std.debug.assert(second.modifiers & ~(modifier_ctrl | modifier_shift | modifier_alt | modifier_meta) == 0);
    if (first.modifiers != second.modifiers) {
        return false;
    }
    if (std.mem.eql(u8, first_key, second_key)) {
        return true;
    }
    return (std.mem.eql(u8, first_key, "plus") and std.mem.eql(u8, second_key, "equal")) or
        (std.mem.eql(u8, first_key, "equal") and std.mem.eql(u8, second_key, "plus"));
}
