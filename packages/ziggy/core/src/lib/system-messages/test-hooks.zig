//
// The test hooks' system messages: test-result, which carries what the frontend found for a test control request, and
// test-ui-ready, which tells the main thread the frontend is listening for test commands. The main thread handles them only in a test
// hooks build.
//

const std = @import("std");
const json = @import("../json.zig");
const test_commands = @import("../test-commands.zig");
const Timers = @import("../timers.zig").Timers;

//
// The data of test-result.
//
pub const TestResultRequest = struct {
    // The test control request the result is for.
    requestId: u32,
    // What the frontend found, or null.
    result: std.json.Value = .null,
};

//
// The message response to test-result and to test-ui-ready, an empty object.
//
pub const DoneResponse = struct {};

//
// Handles test-result: hands the result the frontend computed for a test control request to the connection waiting for it.
//
pub fn testResult(tests: *test_commands.TestCommands, io: std.Io, allocator: std.mem.Allocator, timers: Timers, request: TestResultRequest) !DoneResponse {
    const result_json = try json.stringify(allocator, request.result);
    defer allocator.free(result_json);
    try tests.result(io, allocator, timers, request.requestId, result_json);
    return .{};
}

//
// Handles test-ui-ready: tells the test control connection the frontend has loaded.
//
pub fn testUiReady(tests: *test_commands.TestCommands, io: std.Io, allocator: std.mem.Allocator, timers: Timers) !DoneResponse {
    try tests.uiReady(io, allocator, timers);
    return .{};
}
