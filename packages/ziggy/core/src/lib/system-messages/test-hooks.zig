//
// The test hooks' system messages: test-result, which carries what the frontend found for a test control request, and
// test-ui-ready, which tells the core the frontend is listening for test commands. The core registers them only in a test hooks build.
//

const std = @import("std");
const json = @import("../json.zig");
const core_lib = @import("../core.zig");
const message_registry = @import("../message-registry.zig");

const Core = core_lib.Core;

//
// Registers the test hooks' system messages.
//
pub fn register(registry: *message_registry.Registry) !void {
    try registry.register("test-result", testResultHandler);
    try registry.register("test-ui-ready", testUiReadyHandler);
}

//
// The data of test-result.
//
const TestResultRequest = struct {
    // The test control request the result answers.
    requestId: u32,
    // What the frontend found, or null.
    result: std.json.Value = .null,
};

//
// The data of test-ui-ready, which has none.
//
const TestUiReadyRequest = struct {};

//
// The message response to test-result and to test-ui-ready, an empty object.
//
const DoneResponse = struct {};

//
// Handles test-result: hands the result the frontend computed for a test control request to the connection waiting for it.
//
fn testResultHandler(core: *Core, arena: std.mem.Allocator, request: TestResultRequest) !DoneResponse {
    const control = core.control orelse {
        return error.TestControlNotRunning;
    };
    try control.setAnswer(request.requestId, try json.stringify(arena, request.result));
    return .{};
}

//
// Handles test-ui-ready: tells the test control connection the frontend has loaded.
//
fn testUiReadyHandler(core: *Core, arena: std.mem.Allocator, request: TestUiReadyRequest) !DoneResponse {
    _ = arena;
    _ = request;
    const control = core.control orelse {
        return error.TestControlNotRunning;
    };
    control.markUiReady();
    return .{};
}
