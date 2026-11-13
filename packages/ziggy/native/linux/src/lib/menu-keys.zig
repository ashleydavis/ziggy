//
// Turns the shortcut parts the core parses (see ziggy_parse_accelerator in ziggy.h) into what GTK wants: a key name that
// gdk_keyval_from_name understands, and GDK modifier flags.
//

const std = @import("std");

//
// The modifier bits the core uses. These match the ZIGGY_MOD_ values in ziggy.h.
//
const ziggy_mod_ctrl: u32 = 1;
const ziggy_mod_shift: u32 = 2;
const ziggy_mod_alt: u32 = 4;
const ziggy_mod_meta: u32 = 8;

//
// GDK's modifier flags, from gdktypes.h.
//
pub const gdk_shift_mask: c_uint = 1 << 0;
pub const gdk_control_mask: c_uint = 1 << 2;
pub const gdk_alt_mask: c_uint = 1 << 3;
pub const gdk_super_mask: c_uint = 1 << 26;

//
// The GDK name of each of the core's named keys.
//
const named_keys = [_]struct {
    // The core's name for the key.
    core_name: []const u8,
    // The name GDK knows it by.
    gdk_name: []const u8,
}{
    .{ .core_name = "plus", .gdk_name = "plus" },
    .{ .core_name = "minus", .gdk_name = "minus" },
    .{ .core_name = "equal", .gdk_name = "equal" },
    .{ .core_name = "space", .gdk_name = "space" },
    .{ .core_name = "enter", .gdk_name = "Return" },
    .{ .core_name = "tab", .gdk_name = "Tab" },
    .{ .core_name = "escape", .gdk_name = "Escape" },
    .{ .core_name = "up", .gdk_name = "Up" },
    .{ .core_name = "down", .gdk_name = "Down" },
    .{ .core_name = "left", .gdk_name = "Left" },
    .{ .core_name = "right", .gdk_name = "Right" },
    .{ .core_name = "home", .gdk_name = "Home" },
    .{ .core_name = "end", .gdk_name = "End" },
    .{ .core_name = "pageup", .gdk_name = "Page_Up" },
    .{ .core_name = "pagedown", .gdk_name = "Page_Down" },
    .{ .core_name = "delete", .gdk_name = "Delete" },
    .{ .core_name = "backspace", .gdk_name = "BackSpace" },
};

//
// The GDK name for a key the core named: a letter or digit stays as it is, f12 becomes F12, ? is the keysym question, and the rest
// are looked up. The name is written into the buffer, NUL terminated, and the slice returned excludes the NUL.
//
pub fn gdkKeyName(buffer: *[32]u8, core_key: []const u8) error{UnknownKey}![:0]const u8 {
    // ? stands for no single keyval name: the keysym is "question".
    if (std.mem.eql(u8, core_key, "?")) {
        @memcpy(buffer[0..8], "question");
        buffer[8] = 0;
        return buffer[0..8 :0];
    }
    if (core_key.len == 1) {
        buffer[0] = core_key[0];
        buffer[1] = 0;
        return buffer[0..1 :0];
    }
    if (core_key.len >= 2 and core_key[0] == 'f' and std.ascii.isDigit(core_key[1])) {
        buffer[0] = 'F';
        @memcpy(buffer[1..core_key.len], core_key[1..]);
        buffer[core_key.len] = 0;
        return buffer[0..core_key.len :0];
    }
    for (named_keys) |entry| {
        if (std.mem.eql(u8, entry.core_name, core_key)) {
            @memcpy(buffer[0..entry.gdk_name.len], entry.gdk_name);
            buffer[entry.gdk_name.len] = 0;
            return buffer[0..entry.gdk_name.len :0];
        }
    }
    return error.UnknownKey;
}

//
// The GDK key names of the modifier keys a shortcut holds, in the order a keyboard presses them, and how many of the names are used.
//
pub const ModifierKeys = struct {
    // The key names, used from the start.
    names: [4][:0]const u8,
    // How many of names are used.
    count: u32,
};

//
// The GDK key names of the modifier keys the core's modifier bits name, in the order a keyboard presses them.
//
pub fn gdk_modifier_key_names(core_modifiers: u32) ModifierKeys {
    var result = ModifierKeys{
        .names = undefined,
        .count = 0,
    };
    var count: usize = 0;
    if (core_modifiers & ziggy_mod_ctrl != 0) {
        result.names[count] = "Control_L";
        count += 1;
    }
    if (core_modifiers & ziggy_mod_shift != 0) {
        result.names[count] = "Shift_L";
        count += 1;
    }
    if (core_modifiers & ziggy_mod_alt != 0) {
        result.names[count] = "Alt_L";
        count += 1;
    }
    if (core_modifiers & ziggy_mod_meta != 0) {
        result.names[count] = "Super_L";
        count += 1;
    }
    result.count = @intCast(count);
    std.debug.assert(result.count <= 4);
    return result;
}

//
// The GDK modifier mask a modifier key of gdk_modifier_key_names sets, or error.UnknownModifierKey for any other name.
//
pub fn gdk_modifier_mask(name: []const u8) error{UnknownModifierKey}!c_uint {
    if (std.mem.eql(u8, name, "Control_L")) {
        return gdk_control_mask;
    }
    if (std.mem.eql(u8, name, "Shift_L")) {
        return gdk_shift_mask;
    }
    if (std.mem.eql(u8, name, "Alt_L")) {
        return gdk_alt_mask;
    }
    if (std.mem.eql(u8, name, "Super_L")) {
        return gdk_super_mask;
    }
    return error.UnknownModifierKey;
}

//
// One key of the layout that types a keyval, as GdkKeymapKey gives it. This file imports only std, so it has its own copy of the
// three fields a key press needs.
//
pub const KeyEntry = struct {
    // The key's hardware code.
    keycode: u32,
    // The keyboard group the key belongs to.
    group: i32,
    // The level of the key: 0 types the keyval with no modifier, 1 with Shift.
    level: i32,
};

//
// The entry in group 0 with the lowest level, the first such entry on a tie, or null when no entry is in group 0.
//
pub fn lowest_level_key(entries: []const KeyEntry) ?KeyEntry {
    var best: ?KeyEntry = null;
    for (entries) |entry| {
        if (entry.group != 0) {
            continue;
        }
        if (best) |current| {
            if (entry.level < current.level) {
                best = entry;
            }
        }
        else {
            best = entry;
        }
    }
    if (best) |chosen| {
        std.debug.assert(chosen.group == 0);
    }
    return best;
}

//
// One key event of a key press: whether it is a release, which modifier key it is (an index into the masks the steps were made
// from) or null for the shortcut's own key, and the modifier mask the event carries.
//
pub const KeyPressStep = struct {
    // Whether the event releases the key.
    is_release: bool,
    // Which modifier key the event is, or null for the shortcut's own key.
    modifier_index: ?u32,
    // The modifier mask the event carries.
    state: c_uint,
};

//
// The events that press and release a key with its modifier keys, as a keyboard does: each modifier key down in order, the key down
// and up, then each modifier key up in reverse order. The buffer holds at most four modifiers, so ten steps.
//
pub fn key_press_steps(buffer: *[10]KeyPressStep, modifier_masks: []const c_uint) []KeyPressStep {
    std.debug.assert(modifier_masks.len <= 4);
    var count: usize = 0;
    var index: usize = 0;
    while (index < modifier_masks.len) : (index += 1) {
        buffer[count] = .{
            .is_release = false,
            .modifier_index = @intCast(index),
            .state = modifier_mask_before(modifier_masks, index),
        };
        count += 1;
    }
    const all_masks = modifier_mask_before(modifier_masks, modifier_masks.len);
    buffer[count] = .{
        .is_release = false,
        .modifier_index = null,
        .state = all_masks,
    };
    count += 1;
    buffer[count] = .{
        .is_release = true,
        .modifier_index = null,
        .state = all_masks,
    };
    count += 1;
    index = modifier_masks.len;
    while (index > 0) {
        index -= 1;
        // A release carries the modifiers still down, the one released among them, as X reports a release.
        buffer[count] = .{
            .is_release = true,
            .modifier_index = @intCast(index),
            .state = modifier_mask_before(modifier_masks, index + 1),
        };
        count += 1;
    }
    std.debug.assert(count <= 10);
    return buffer[0..count];
}

//
// The masks of the modifiers before the one at the index, OR'd together.
//
fn modifier_mask_before(modifier_masks: []const c_uint, index: usize) c_uint {
    std.debug.assert(index <= modifier_masks.len);
    var state: c_uint = 0;
    for (modifier_masks[0..index]) |mask| {
        state |= mask;
    }
    return state;
}

//
// GDK's modifier flags for the core's modifier bits.
//
pub fn gdkModifiers(core_modifiers: u32) c_uint {
    var result: c_uint = 0;
    if (core_modifiers & ziggy_mod_ctrl != 0) {
        result |= gdk_control_mask;
    }
    if (core_modifiers & ziggy_mod_shift != 0) {
        result |= gdk_shift_mask;
    }
    if (core_modifiers & ziggy_mod_alt != 0) {
        result |= gdk_alt_mask;
    }
    if (core_modifiers & ziggy_mod_meta != 0) {
        result |= gdk_super_mask;
    }
    return result;
}
