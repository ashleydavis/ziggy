//
// Hello world example: change it into your own tests, or delete it.
//
// Each test starts the app's backend with a fake native app, chooses a menu item as the native app would and checks what the UI is sent.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const app = @import("ziggy-template-backend");

const FakeShell = ziggy.fake_shell.FakeShell;

test "the Hello menu has a Zig item and a UI item" {
    const from_zig = app.app.menu_targets.get("hello-from-zig") orelse return error.MenuItemMissing;
    try std.testing.expect(from_zig == .zig);
    const from_ui = app.app.menu_targets.get("hello-from-ui") orelse return error.MenuItemMissing;
    try std.testing.expect(from_ui == .ui);
}

test "Say Hello From Zig sends the UI the hello-from-zig event" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(2, 2), app.app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"hello-from-zig\"}}");
    try shell.expectMessageContaining("{\"kind\":\"app\",\"data\":{\"type\":\"hello-from-zig\",\"text\":\"Hello from Zig, run from the menu\"}}");
}

test "Say Hello From the UI sends the UI the menu event naming it" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(2, 2), app.app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"id\":1,\"name\":\"menu-action\",\"data\":{\"action\":\"hello-from-ui\"}}");
    try shell.expectMessageContaining("{\"kind\":\"app\",\"data\":{\"type\":\"menu\",\"item\":\"hello-from-ui\"}}");
}
