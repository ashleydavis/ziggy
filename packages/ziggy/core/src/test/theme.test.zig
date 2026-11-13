//
// Tests of the theme setting: parsing, resolving, taking --theme from the command line, the run's state, its JSON and the window
// background colour text.
//

const std = @import("std");
const ziggy = @import("ziggy");

const theme = ziggy.theme;

test "parseSetting reads the three settings" {
    try std.testing.expectEqual(theme.Setting.light, try theme.parseSetting("light"));
    try std.testing.expectEqual(theme.Setting.dark, try theme.parseSetting("dark"));
    try std.testing.expectEqual(theme.Setting.system, try theme.parseSetting("system"));
}

test "parseSetting rejects any other text" {
    try std.testing.expectError(error.UnknownTheme, theme.parseSetting("Light"));
    try std.testing.expectError(error.UnknownTheme, theme.parseSetting(""));
}

test "resolve gives the system theme for system and the setting itself otherwise" {
    try std.testing.expectEqual(theme.Theme.light, theme.resolve(.light, .dark));
    try std.testing.expectEqual(theme.Theme.dark, theme.resolve(.dark, .light));
    try std.testing.expectEqual(theme.Theme.dark, theme.resolve(.system, .dark));
    try std.testing.expectEqual(theme.Theme.light, theme.resolve(.system, .light));
}

test "--theme and its value are taken out, and the rest pass through in order" {
    const taken = try theme.takeArgument(std.testing.allocator, &.{ "--open", "a.txt", "--theme", "dark", "-geometry=800x600" });
    defer std.testing.allocator.free(taken.remaining);
    try std.testing.expectEqual(theme.Setting.dark, taken.setting.?);
    try std.testing.expectEqual(@as(usize, 3), taken.remaining.len);
    try std.testing.expectEqualStrings("--open", taken.remaining[0]);
    try std.testing.expectEqualStrings("a.txt", taken.remaining[1]);
    try std.testing.expectEqualStrings("-geometry=800x600", taken.remaining[2]);
}

test "an argument list without --theme passes through unchanged" {
    const arguments = [_][]const u8{ "--open", "a.txt" };
    const taken = try theme.takeArgument(std.testing.allocator, &arguments);
    defer std.testing.allocator.free(taken.remaining);
    try std.testing.expect(taken.setting == null);
    try std.testing.expectEqual(arguments.len, taken.remaining.len);
    for (arguments, taken.remaining) |given, passed| {
        try std.testing.expectEqualStrings(given, passed);
    }
}

test "--theme with no value after it is an error" {
    try std.testing.expectError(error.ThemeValueMissing, theme.takeArgument(std.testing.allocator, &.{ "--open", "--theme" }));
}

test "--theme given twice is an error" {
    try std.testing.expectError(error.ThemeGivenTwice, theme.takeArgument(std.testing.allocator, &.{ "--theme", "light", "--theme", "dark" }));
}

test "--theme with a value that is not a setting is an error" {
    try std.testing.expectError(error.UnknownTheme, theme.takeArgument(std.testing.allocator, &.{ "--theme", "night" }));
}

test "running out of memory taking --theme fails cleanly" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, takeAndFree, .{});
}

//
// Takes --theme from an argument list and frees what it made, for the allocation failure test.
//
fn takeAndFree(allocator: std.mem.Allocator) !void {
    const taken = try theme.takeArgument(allocator, &.{ "--open", "a.txt", "--theme", "dark", "x" });
    allocator.free(taken.remaining);
}

test "applySetting reports a change of the setting or the theme, and nothing otherwise" {
    var state: theme.ThemeState = .{ .setting = .light, .system = .light };
    try std.testing.expect(!state.applySetting(.light));
    try std.testing.expect(state.applySetting(.dark));
    try std.testing.expect(state.applySetting(.system));
    try std.testing.expectEqual(theme.Theme.light, state.theme());
    try std.testing.expect(state.applySystem(.dark));
    try std.testing.expectEqual(theme.Theme.dark, state.theme());
    try std.testing.expect(!state.applySystem(.dark));
}

test "applySetting reports a change when the setting changes and the theme does not" {
    var state: theme.ThemeState = .{ .setting = .dark, .system = .dark };
    try std.testing.expect(state.applySetting(.system));
    try std.testing.expectEqual(theme.Theme.dark, state.theme());
}

test "applySystem reports nothing when the setting is not system" {
    var state: theme.ThemeState = .{ .setting = .light, .system = .dark };
    try std.testing.expect(!state.applySystem(.dark));
    try std.testing.expectEqual(theme.Theme.light, state.theme());
}

test "stateJson gives the setting and the theme" {
    const text = try theme.stateJson(std.testing.allocator, .{ .setting = .system, .system = .dark });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"setting\":\"system\",\"theme\":\"dark\"}", text);
}

test "stateJson runs out of memory cleanly" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, stateJsonAndFree, .{});
}

//
// Makes the state's JSON and frees it, for the allocation failure test.
//
fn stateJsonAndFree(allocator: std.mem.Allocator) !void {
    const text = try theme.stateJson(allocator, .{ .setting = .light, .system = .dark });
    allocator.free(text);
}

test "backgroundText gives the theme's colour as #rrggbb in lower case" {
    const backgrounds: theme.Backgrounds = .{ .light = 0xffffff, .dark = 0x000000 };
    const light = try theme.backgroundText(std.testing.allocator, backgrounds, .light);
    defer std.testing.allocator.free(light);
    try std.testing.expectEqualStrings("#ffffff", light);
    const dark = try theme.backgroundText(std.testing.allocator, backgrounds, .dark);
    defer std.testing.allocator.free(dark);
    try std.testing.expectEqualStrings("#000000", dark);
}

test "backgroundText pads a colour with leading zeros" {
    const backgrounds: theme.Backgrounds = .{ .light = 0x0000ff, .dark = 0x000000 };
    const text = try theme.backgroundText(std.testing.allocator, backgrounds, .light);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("#0000ff", text);
}

test "backgroundText runs out of memory cleanly" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, backgroundTextAndFree, .{});
}

//
// Makes the background text and frees it, for the allocation failure test.
//
fn backgroundTextAndFree(allocator: std.mem.Allocator) !void {
    const text = try theme.backgroundText(allocator, .{}, .dark);
    allocator.free(text);
}
