//
// Hello world example: change it into your own tests, or delete it.
//
// Each test starts the app's backend with a fake native app, sends it what the UI would send and checks what comes back.
//

const std = @import("std");
const ziggy = @import("ziggy");
const app = @import("ziggy-template-backend");

const FakeShell = ziggy.fake_shell.FakeShell;

test "the hello-world message is answered with a greeting for the name it sent" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(2, 2), app.app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"hello-world\",\"data\":{\"name\":\"world\"}}");
    try shell.expectMessageContaining("\"greeting\":\"Hello world, from Zig on");
}

test "a hello-world message with no name is refused as InvalidMessageData naming the field" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(2, 2), app.app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"hello-world\"}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"name\\\" is missing\"}");
}

test "the hello-world task sends its output and completes" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(2, 2), app.app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"t1\",\"taskType\":\"hello-world-task\",\"source\":\"hello\",\"data\":null}}");
    try shell.expectMessageContaining("\"text\":\"Hello world from a task\"");
    try shell.expectMessageContaining("\"status\":\"succeeded\",\"outputs\":\"hello world task done\"");
}

test "a message of a name the template does not know is answered with UnknownMessageName" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(2, 2), app.app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"name\":\"goodbye-world\"}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"UnknownMessageName\"}");
}

test "a message with no name is refused with MissingMessageName" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(2, 2), app.app);
    defer core.destroy();
    core.postMessage("{\"kind\":\"app\",\"id\":1,\"data\":{\"name\":\"world\"}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"MissingMessageName\"}");
}
