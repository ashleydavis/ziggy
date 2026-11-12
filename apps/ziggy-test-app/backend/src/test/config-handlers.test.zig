//
// The test app's handlers that read the config file: a message, a task and a menu item, each reading test.value.
//

const std = @import("std");
const ziggy = @import("ziggy");
const template = @import("ziggy-test-app-backend");
const test_environment = @import("test-environment.zig");

const FakeNativeApp = ziggy.fake_native_app.FakeNativeApp;

//
// Starts the test app's core with config and state directories of the test's own, and returns the config file's path. The file holds
// test.value when a value is given.
//
fn startApp(native_app: *FakeNativeApp, arena: std.mem.Allocator, value: ?[]const u8) !void {
    const directories = try test_environment.useTestEnvironment(std.testing.allocator, native_app.data_tmp);
    defer test_environment.freeTestEnvironment(std.testing.allocator, directories);
    const data_dir = std.mem.sliceTo(&native_app.data_dir_path, 0);
    const config_dir = try std.fs.path.join(arena, &.{ data_dir, "config" });
    const config_path = try std.fs.path.join(arena, &.{ config_dir, "config.toml" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, config_dir);
    if (value) |found| {
        try ziggy.config_state.config.set(arena, std.testing.io, config_path, "test.value", found);
    }
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), template.app);
}

test "the read-config message replies with the config file's value, and null when it is absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startApp(&native_app, arena, "blue");
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"read-config\",\"data\":{}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true,\"data\":\"blue\"}");

    var absent_app: FakeNativeApp = undefined;
    absent_app.init();
    defer absent_app.deinit(std.testing.io, std.testing.allocator);
    try startApp(&absent_app, arena, null);
    defer absent_app.stop(std.testing.io, std.testing.allocator);
    absent_app.sendMessage(std.testing.allocator, "{\"kind\":\"app\",\"id\":2,\"name\":\"read-config\",\"data\":{}}");
    try absent_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":true,\"data\":null}");
}

test "the read-config task replies with the config file's value, and null when it is absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startApp(&native_app, arena, "blue");
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"add-task\",\"data\":{\"taskId\":\"read-config-1\",\"taskType\":\"read-config\",\"source\":\"config-source\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"read-config-1\",\"result\":{\"taskId\":\"read-config-1\",\"status\":\"succeeded\",\"outputs\":\"blue\"");

    var absent_app: FakeNativeApp = undefined;
    absent_app.init();
    defer absent_app.deinit(std.testing.io, std.testing.allocator);
    try startApp(&absent_app, arena, null);
    defer absent_app.stop(std.testing.io, std.testing.allocator);
    absent_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"add-task\",\"data\":{\"taskId\":\"read-config-2\",\"taskType\":\"read-config\",\"source\":\"config-source\"}}");
    try absent_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"read-config-2\",\"result\":{\"taskId\":\"read-config-2\",\"status\":\"succeeded\",\"type\":\"read-config\"");
}

test "the Read Config menu item sends the app event with the config file's value, and null when it is absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try startApp(&native_app, arena, "blue");
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"read-config\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"config-from-menu\",\"value\":\"blue\"}}");

    var absent_app: FakeNativeApp = undefined;
    absent_app.init();
    defer absent_app.deinit(std.testing.io, std.testing.allocator);
    try startApp(&absent_app, arena, null);
    defer absent_app.stop(std.testing.io, std.testing.allocator);
    absent_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"menu-action\",\"data\":{\"action\":\"read-config\"}}");
    try absent_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"config-from-menu\",\"value\":null}}");
}
