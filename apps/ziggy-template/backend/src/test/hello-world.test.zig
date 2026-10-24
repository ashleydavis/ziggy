//
// Hello world example: change it into your own tests, or delete it.
//
// Each test starts the app's backend with a fake native app, sends it what the frontend would send and checks what comes back.
//

const std = @import("std");
const ziggy = @import("ziggy");
const app = @import("ziggy-template-backend");

const FakeNativeApp = ziggy.fake_native_app.FakeNativeApp;

test "the hello-world message is answered with a greeting for the name it sent" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(2, 2), app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"hello-world\",\"data\":{\"name\":\"world\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"greeting\":\"Hello world, from Zig on");
}

test "a hello-world message with no name is refused as InvalidMessageData naming the field" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(2, 2), app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"hello-world\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"name\\\" is missing\"}");
}

test "the hello-world task sends its output and completes" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(2, 2), app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"t1\",\"taskType\":\"hello-world-task\",\"source\":\"hello\",\"data\":null}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"text\":\"Hello world from a task\"");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"succeeded\",\"outputs\":\"hello world task done\"");
}

test "a message of a name the template does not know is answered with UnknownMessageName" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(2, 2), app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"name\":\"goodbye-world\"}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"UnknownMessageName\"}");
}

test "a message with no name is refused with MissingMessageName" {
    var native_app: FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(2, 2), app.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try native_app.send(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"id\":1,\"data\":{\"name\":\"world\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"MissingMessageName\"}");
}
