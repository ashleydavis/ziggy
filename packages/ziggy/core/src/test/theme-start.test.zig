//
// Tests of the theme at start-up: the setting from --theme, from the config file or from neither, the system's theme, and the
// arguments on_create receives.
//

const std = @import("std");
const ziggy = @import("ziggy");
const test_app = @import("test-app.zig");

const core = ziggy.core;
const Timers = ziggy.timers.Timers;
const FakeNativeApp = ziggy.fake_native_app.FakeNativeApp;

//
// The directories of the config and state files the test's core reads and writes.
//
const FileDirectories = struct {
    // The directory of the config file.
    config_dir: []const u8,
    // The directory of the state file.
    state_dir: []const u8,
};

//
// Sets the process environment so the core's files go in directories of the test's own, and returns their paths.
//
fn setUpFileDirectories(
    tmp: *std.testing.TmpDir,
    arena_state: *std.heap.ArenaAllocator,
    map: *std.process.Environ.Map,
) !FileDirectories {
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const config_dir = try std.fs.path.join(arena, &.{ root, "config" });
    const state_dir = try std.fs.path.join(arena, &.{ root, "state" });
    map.* = try std.testing.environ.createMap(std.testing.allocator);
    try map.put(try ziggy.config_state.platform.appVariableName(arena, "core-test", "_CONFIG_DIR"), config_dir);
    try map.put(try ziggy.config_state.platform.appVariableName(arena, "core-test", "_STATE_DIR"), state_dir);
    ziggy.utils.process_env.setEnvironMap(map);
    return .{ .config_dir = config_dir, .state_dir = state_dir };
}

//
// on_create: sends the arguments it was given as an event, so a test can see --theme was taken out of them.
//
fn recordArguments(services: core.HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) anyerror!void {
    _ = timers;
    try services.sendEvent(io, allocator, try ziggy.json.stringify(allocator, arguments));
}

//
// The test app with the name and title the config and state files need, and an on_create that records its arguments.
//
const app_with_arguments = blk: {
    var copy = test_app.app;
    copy.name = "core-test";
    copy.title = "Core test";
    copy.on_create = recordArguments;
    break :blk copy;
};

//
// The theme the core reports, allocated with the test's allocator.
//
fn themeText(native_app: *FakeNativeApp) ![:0]u8 {
    return try native_app.theme(std.testing.allocator);
}

//
// Writes the config file's text in the test's config directory, making the directory first.
//
fn writeConfig(arena: std.mem.Allocator, directories: FileDirectories, text: []const u8) !void {
    const config_path = try std.fs.path.join(arena, &.{ directories.config_dir, "config.toml" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, directories.config_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = text });
}

//
// Whether any line of the app's file log contains the text.
//
fn logContains(arena: std.mem.Allocator, native_app: *FakeNativeApp, text: []const u8) !bool {
    const logs_dir = try std.fs.path.join(arena, &.{ std.mem.sliceTo(&native_app.data_dir_path, 0), "logs" });
    var directory = std.Io.Dir.cwd().openDir(std.testing.io, logs_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        const log_text = try directory.readFileAlloc(std.testing.io, entry.name, arena, .limited(1024 * 1024));
        if (std.mem.indexOf(u8, log_text, text) != null) {
            return true;
        }
    }
    return false;
}

test "no --theme and no config gives the system setting and the system's light theme" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    _ = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();

    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), app_with_arguments);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const text = try themeText(&native_app);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"type\":\"theme\",\"setting\":\"system\",\"theme\":\"light\",\"background\":\"#ffffff\"}", text);
}

test "the system's dark theme is the theme for the system setting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    _ = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();

    var config = native_app.config(1, 1);
    config.system_theme = 1;
    try native_app.start(std.testing.io, std.testing.allocator, config, app_with_arguments);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const text = try themeText(&native_app);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"type\":\"theme\",\"setting\":\"system\",\"theme\":\"dark\",\"background\":\"#000000\"}", text);
}

test "--theme sets the theme for the run and is taken out of the arguments on_create receives" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    _ = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();

    const arguments = [_][:0]const u8{ "--open", "a.txt", "--theme", "dark" };
    var pointers: [arguments.len][*:0]const u8 = undefined;
    for (arguments, 0..) |argument, index| {
        pointers[index] = argument.ptr;
    }
    var config = native_app.config(1, 1);
    config.arg_count = arguments.len;
    config.args = &pointers;
    try native_app.start(std.testing.io, std.testing.allocator, config, app_with_arguments);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const text = try themeText(&native_app);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"type\":\"theme\",\"setting\":\"dark\",\"theme\":\"dark\",\"background\":\"#000000\"}", text);
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "[\"--open\",\"a.txt\"]");
}

test "a bad --theme fails the start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    _ = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();

    const arguments = [_][:0]const u8{ "--theme", "night" };
    var pointers: [arguments.len][*:0]const u8 = undefined;
    for (arguments, 0..) |argument, index| {
        pointers[index] = argument.ptr;
    }
    var config = native_app.config(1, 1);
    config.arg_count = arguments.len;
    config.args = &pointers;
    try std.testing.expectError(error.UnknownTheme, native_app.start(std.testing.io, std.testing.allocator, config, app_with_arguments));
}

test "the config file's theme sets the setting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    const directories = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();
    try writeConfig(arena_state.allocator(), directories, "theme = \"light\"\n");

    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), app_with_arguments);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const text = try themeText(&native_app);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"type\":\"theme\",\"setting\":\"light\",\"theme\":\"light\",\"background\":\"#ffffff\"}", text);
}

test "an unknown config value leaves the setting system and logs the value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    const directories = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();
    try writeConfig(arena_state.allocator(), directories, "theme = \"night\"\n");

    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), app_with_arguments);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const text = try themeText(&native_app);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"type\":\"theme\",\"setting\":\"system\",\"theme\":\"light\",\"background\":\"#ffffff\"}", text);
    try std.testing.expect(try logContains(arena_state.allocator(), &native_app, "The config file's theme \"night\" is not light, dark or system, so the theme setting is system."));
}

test "a config theme that is not a string leaves the setting system and logs that it could not be read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    const directories = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();
    try writeConfig(arena_state.allocator(), directories, "theme = 1\n");

    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), app_with_arguments);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const text = try themeText(&native_app);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"type\":\"theme\",\"setting\":\"system\",\"theme\":\"light\",\"background\":\"#ffffff\"}", text);
    try std.testing.expect(try logContains(arena_state.allocator(), &native_app, "The config file's theme could not be read ("));
}

test "an unknown system theme fails the start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    _ = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();

    var config = native_app.config(1, 1);
    config.system_theme = 2;
    try std.testing.expectError(error.UnknownSystemTheme, native_app.start(std.testing.io, std.testing.allocator, config, app_with_arguments));
}

test ".backgrounds reaches the theme JSON" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const previous = ziggy.utils.process_env.getEnvironMap();
    defer ziggy.utils.process_env.setEnvironMap(previous);
    var map: std.process.Environ.Map = undefined;
    _ = try setUpFileDirectories(&tmp, &arena_state, &map);
    defer map.deinit();

    var app = app_with_arguments;
    app.backgrounds = .{
        .light = 0x123456,
        .dark = 0xabcdef,
    };
    var config = native_app.config(1, 1);
    config.system_theme = 1;
    try native_app.start(std.testing.io, std.testing.allocator, config, app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const text = try themeText(&native_app);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"type\":\"theme\",\"setting\":\"system\",\"theme\":\"dark\",\"background\":\"#abcdef\"}", text);
}
