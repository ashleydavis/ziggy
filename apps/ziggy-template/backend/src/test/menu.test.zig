//
// Hello world example: change it into your own tests, or delete it.
//
// Each test starts the app's backend with a fake native app, chooses a menu item as the native app would and checks what the frontend is sent.
//

const std = @import("std");
const ziggy = @import("ziggy");
const app = @import("ziggy-template-backend");

const FakeNativeApp = ziggy.fake_native_app.FakeNativeApp;

test "the Hello menu has a Zig item and a UI item" {
    const from_zig = app.app.menu_targets.get("hello-from-zig") orelse return error.MenuItemMissing;
    try std.testing.expect(from_zig == .zig);
    const from_ui = app.app.menu_targets.get("hello-from-ui") orelse return error.MenuItemMissing;
    try std.testing.expect(from_ui == .ui);
}

test "Say Hello From Zig sends the UI the hello-from-zig event" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(2, 2), app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"hello-from-zig\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"hello-from-zig\",\"text\":\"Hello from Zig, run from the menu\"}}");
}

test "Say Hello From the UI sends the UI the menu event naming it" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(2, 2), app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"hello-from-ui\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"menu\",\"item\":\"hello-from-ui\"}}");
}
