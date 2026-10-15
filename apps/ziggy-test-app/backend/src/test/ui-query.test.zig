const std = @import("std");
const ziggy = @import("ziggy-core");
const template = @import("ziggy-test-app-backend");

const FakeShell = ziggy.fake_shell.FakeShell;

test "the test app's UI query says the test mode switch and nothing else" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), template.app);
    defer core.destroy();
    const without = try template.app.ui_query.?(core, std.testing.allocator, false);
    defer std.testing.allocator.free(without);
    try std.testing.expectEqualStrings("", without);
    const with = try template.app.ui_query.?(core, std.testing.allocator, true);
    defer std.testing.allocator.free(with);
    try std.testing.expectEqualStrings("testMode=1", with);
}

test "the test app core gives the UI an empty query outside test mode" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), template.app);
    defer core.destroy();
    try std.testing.expectEqualStrings("", try core.uiQuery());
}
