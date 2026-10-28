//
// The system messages of the remote control connection: test-result, which carries what the frontend found for a remote control
// request, and test-ui-ready, which tells the main thread the frontend is listening for test commands. Every build handles them, and
// they fail with RemoteControlNotRunning when the app was started without --remote-control.
//

const std = @import("std");
const json = @import("../json.zig");
const test_commands = @import("../test-commands.zig");
const Timers = @import("../timers.zig").Timers;

//
// The data of test-result.
//
pub const TestResultRequest = struct {
    // The remote control request the result is for.
    requestId: u32,
    // What the frontend found, or null.
    result: std.json.Value = .null,
};

//
// The message response to test-result and to test-ui-ready, an empty object.
//
pub const DoneResponse = struct {};

//
// Handles test-result: hands the result the frontend computed for a remote control request to the connection waiting for it.
//
pub fn testResult(tests: *test_commands.TestCommands, io: std.Io, allocator: std.mem.Allocator, timers: Timers, request: TestResultRequest) !DoneResponse {
    const result_json = try json.stringify(allocator, request.result);
    defer allocator.free(result_json);
    try tests.result(io, allocator, timers, request.requestId, result_json);
    return .{};
}

//
// Handles test-ui-ready: tells the remote control connection the frontend has loaded.
//
pub fn testUiReady(tests: *test_commands.TestCommands, io: std.Io, allocator: std.mem.Allocator, timers: Timers) !DoneResponse {
    try tests.uiReady(io, allocator, timers);
    return .{};
}
