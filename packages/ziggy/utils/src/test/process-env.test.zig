const std = @import("std");
const utils = @import("utils");
const process_env = utils.process_env;
const MessageQueue = @import("ziggy").core.MessageQueue;
const ThreadAllocator = @import("utils").thread_allocator.ThreadAllocator;

test "getEnv returns null until an environment is set" {
    process_env.setEnvironMap(null);
    try std.testing.expect(process_env.getEnv("PATH") == null);
}

test "getEnv reads the environment set with setEnvironMap" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("ZIGGY_TEST", "value");
    process_env.setEnvironMap(&environ_map);
    defer process_env.setEnvironMap(null);

    try std.testing.expectEqualStrings("value", process_env.getEnv("ZIGGY_TEST").?);
    try std.testing.expect(process_env.getEnv("PHOTOSPHERE_MISSING") == null);
}

test "getEnvironMap returns the environment set with setEnvironMap" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    process_env.setEnvironMap(&environ_map);
    try std.testing.expect(process_env.getEnvironMap() == &environ_map);
    process_env.setEnvironMap(null);
    try std.testing.expect(process_env.getEnvironMap() == null);
}

//
// Reads ZIGGY_TEST on a thread of its own, which has set no environment, and tells the test's thread on the queue given what it found:
// the value as a JSON string, or null.
//
fn readOnAnotherThread(replies: *MessageQueue) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const found = std.json.Stringify.valueAlloc(allocator, process_env.getEnv("ZIGGY_TEST"), .{}) catch @panic("out of memory");
    defer allocator.free(found);
    replies.post(threaded.io(), 0, found) catch @panic("out of memory replying to the test");
}

test "an environment set on one thread is not the environment of another" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("ZIGGY_TEST", "value");
    process_env.setEnvironMap(&environ_map);
    defer process_env.setEnvironMap(null);
    var replies = MessageQueue.init();
    defer replies.deinit();
    const other = try std.Thread.spawn(.{}, readOnAnotherThread, .{&replies});
    other.join();
    const found = replies.take(std.testing.io, std.testing.allocator, .none).?;
    defer std.testing.allocator.free(found.text);
    try std.testing.expectEqualStrings("null", found.text);
    try std.testing.expectEqualStrings("value", process_env.getEnv("ZIGGY_TEST").?);
}

test "copyEnvironMap copies every name and value into an environment of its own" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("ONE", "1");
    try environ_map.put("TWO", "2");
    var copy = try process_env.copyEnvironMap(std.testing.allocator, &environ_map);
    defer copy.deinit();
    try environ_map.put("ONE", "changed");
    try std.testing.expectEqualStrings("1", copy.get("ONE").?);
    try std.testing.expectEqualStrings("2", copy.get("TWO").?);
}
