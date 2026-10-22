const std = @import("std");
const ziggy = @import("ziggy");
const template = @import("ziggy-test-app-backend");

const FakeShell = ziggy.fake_shell.FakeShell;

//
// Creates a backend on the fake native app, which handles dialogs with a callback which returns the arguments it was called with as its result.
//
fn createCore(shell: *FakeShell) !*ziggy.core.Core {
    return try ziggy.core.Core.create(std.testing.allocator, shell.config(2, 2), template.app);
}

test "pick-files asks for an open dialog with the title and replies with the paths" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"pick-files\",\"data\":{\"title\":\"Pick some files\"}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":true,\"data\":[\"kind0\",\"Pick some files\",\"-\"]}");
}

test "pick-files with no title uses a default one" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"pick-files\"}");
    try shell.expectMessageContaining("[\"kind0\",\"Select Files\",\"-\"]");
}

test "pick-folder asks for a folder dialog with the title from the options and replies with one path" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":2,\"name\":\"pick-folder\",\"data\":{\"title\":\"Pick a folder\"}}");
    try shell.expectMessageContaining("{\"id\":2,\"ok\":true,\"data\":\"kind2\"}");
}

test "pick-folder with no options uses a default title" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":2,\"name\":\"pick-folder\"}");
    try shell.expectMessageContaining("{\"id\":2,\"ok\":true,\"data\":\"kind2\"}");
}

test "pick-file is a save dialog with the suggested name and replies with one path" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":3,\"name\":\"pick-file\",\"data\":{\"name\":\"photo.jpg\"}}");
    try shell.expectMessageContaining("{\"id\":3,\"ok\":true,\"data\":\"kind1\"}");
}

test "a cancelled dialog is a reply of null" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(2, 2);
    config.pick_paths = FakeShell.pickNothing;
    const core = try ziggy.core.Core.create(std.testing.allocator, config, template.app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":4,\"name\":\"pick-files\",\"data\":{\"title\":\"T\"}}");
    try shell.expectMessageContaining("{\"id\":4,\"ok\":true,\"data\":null}");
    core.postMessage("{\"kind\":\"app\",\"id\":5,\"name\":\"pick-folder\"}");
    try shell.expectMessageContaining("{\"id\":5,\"ok\":true,\"data\":null}");
    core.postMessage("{\"kind\":\"app\",\"id\":6,\"name\":\"pick-file\",\"data\":{\"name\":\"x\"}}");
    try shell.expectMessageContaining("{\"id\":6,\"ok\":true,\"data\":null}");
}

test "a shell with no dialog callback gives an error reply naming what is missing" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(2, 2);
    config.pick_paths = null;
    const core = try ziggy.core.Core.create(std.testing.allocator, config, template.app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":7,\"name\":\"pick-folder\"}");
    try shell.expectMessageContaining("{\"id\":7,\"ok\":false,\"error\":\"HostCallbackMissing\"}");
}
