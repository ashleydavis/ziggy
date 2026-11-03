//
// The actions' system messages: run-action, which window.ziggy.runAction sends to run one of the app's actions by its name, and
// list-actions, which window.ziggy.listActions sends for every action with its label and shortcut.
//

const std = @import("std");
const builtin = @import("builtin");
const shortcut_lib = @import("../shortcut.zig");
const action_lib = @import("../action.zig");
const menu_lib = @import("../menu.zig");
const services_lib = @import("../services.zig");

//
// The data of run-action.
//
pub const RunActionRequest = struct {
    // The name of the action to run: one of the app's actions, or a standard action of the app's menu.
    action: []const u8,
};

//
// The message response to run-action, an empty object.
//
pub const DoneResponse = struct {};

//
// One entry of the message response to list-actions.
//
pub const ActionInfo = struct {
    // The action's name, or the standard action's for a `.standard` item of the menu.
    name: []const u8,
    // The action's label, or the `.standard` item's.
    label: []const u8,
    // The shortcut as the platform shows it, such as "Ctrl+Shift+H" or "⇧⌘H", or null when there is none or on a phone, which
    // registers no shortcut.
    shortcut: ?[]const u8,

    //
    // Writes the entry as JSON with "shortcut" always present, null when there is none, as the frontend's IActionInfo has it. The
    // core's JSON leaves out null fields otherwise.
    //
    pub fn jsonStringify(self: ActionInfo, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        try writer.objectField("name");
        try writer.write(self.name);
        try writer.objectField("label");
        try writer.write(self.label);
        try writer.objectField("shortcut");
        try writer.write(self.shortcut);
        try writer.endObject();
    }
};

//
// Runs the action of the name through the handler services (see HandlerServices.runAction), so the frontend's runAction and the
// backend's run it the same way. Its error is this message's error.
//
pub fn runAction(services: services_lib.HandlerServices, io: std.Io, allocator: std.mem.Allocator, request: RunActionRequest) !DoneResponse {
    try services.runAction(io, allocator, request.action);
    return .{};
}

//
// Lists every action of the app and every `.standard` item of its menu, with its label and its shortcut as the platform the core was
// built for shows it. A phone registers no shortcut, so every shortcut is null there.
//
pub fn listActions(app_actions: []const action_lib.Action, standard_menu_items: []const menu_lib.StandardMenuItem, services: services_lib.HandlerServices, allocator: std.mem.Allocator) ![]ActionInfo {
    const show_shortcuts = !services.isPhone();
    var found: std.ArrayList(ActionInfo) = .empty;
    for (app_actions) |action| {
        try found.append(allocator, .{
            .name = action.name,
            .label = action.label,
            .shortcut = if (show_shortcuts) try formatShortcut(allocator, action.shortcut) else null,
        });
    }
    for (standard_menu_items) |item| {
        try found.append(allocator, .{
            .name = @tagName(item.action),
            .label = item.label,
            .shortcut = if (show_shortcuts) try formatShortcut(allocator, item.shortcut) else null,
        });
    }
    return try found.toOwnedSlice(allocator);
}

//
// Formats the shortcut text as the platform shows it, allocated, or gives null when there is none. The build checked every shortcut,
// so it parses.
//
fn formatShortcut(allocator: std.mem.Allocator, shortcut: ?[]const u8) !?[]const u8 {
    const text = shortcut orelse return null;
    const parsed = shortcut_lib.parse(text) catch |err| {
        std.debug.panic("ziggy: the shortcut \"{s}\", which the build checked, does not parse: {s}", .{ text, @errorName(err) });
    };
    var buffer: [64]u8 = undefined;
    return try allocator.dupe(u8, try shortcut_lib.writeDisplayText(&buffer, parsed, builtin.os.tag));
}
