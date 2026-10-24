const std = @import("std");
const ziggy = @import("ziggy");
const helpers = @import("helpers.zig");

const core = ziggy.core;
const Timers = ziggy.timers.Timers;

//
// A frontend query hook that returns what it was told, so a test can see that the core passed the test mode switch through.
//
fn sayTestMode(services: core.HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, test_mode: bool) anyerror![]const u8 {
    _ = services;
    _ = timers;
    _ = io;
    if (test_mode) {
        return try allocator.dupe(u8, "a=1&mode=on&text=%C3%A9");
    }
    return try allocator.dupe(u8, "a=1&mode=off");
}

fn failToMakeQuery(services: core.HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, test_mode: bool) anyerror![]const u8 {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = test_mode;
    return error.QueryFailed;
}

const app_with_query = blk: {
    var copy = helpers.app;
    copy.ui_query = sayTestMode;
    break :blk copy;
};

const app_with_failing_query = blk: {
    var copy = helpers.app;
    copy.ui_query = failToMakeQuery;
    break :blk copy;
};

test "an app with no UI query hook has an empty query" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const query = try native_app.uiQuery(std.testing.allocator);
    defer std.testing.allocator.free(query);
    try std.testing.expectEqualStrings("", query);
}

test "the query the app makes is passed through unread, with a terminator" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), app_with_query);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const query = try native_app.uiQuery(std.testing.allocator);
    defer std.testing.allocator.free(query);
    try std.testing.expectEqualStrings("a=1&mode=off", query);
    try std.testing.expectEqual(@as(u8, 0), query.ptr[query.len]);
}

test "the app is told whether the test mode switch is on" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    var config = native_app.config(1, 1);
    // The switch is read from the configuration. In a test hooks build it also starts the control connection, which this test does
    // not use.
    config.test_mode = true;
    try native_app.start(std.testing.io, std.testing.allocator, config, app_with_query);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const query = try native_app.uiQuery(std.testing.allocator);
    defer std.testing.allocator.free(query);
    try std.testing.expectEqualStrings("a=1&mode=on&text=%C3%A9", query);
}

//
// How many queries the core's main thread has made, which counts on each main thread from 0 (test-only code).
//
threadlocal var queries_made: u32 = 0;

//
// A frontend query hook that numbers its queries, so a test can see a second query run the app's function again.
//
fn countQueries(services: core.HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, test_mode: bool) anyerror![]const u8 {
    _ = services;
    _ = timers;
    _ = io;
    _ = test_mode;
    queries_made += 1;
    return try std.fmt.allocPrint(allocator, "count={d}", .{queries_made});
}

const app_counting_queries = blk: {
    var copy = helpers.app;
    copy.ui_query = countQueries;
    break :blk copy;
};

test "a second query runs the app's function again" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), app_counting_queries);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const first = try native_app.uiQuery(std.testing.allocator);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("count=1", first);
    const second = try native_app.uiQuery(std.testing.allocator);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("count=2", second);
}

test "a query the app fails to make is an error, not an empty query" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), app_with_failing_query);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    // The app's error is named in what is printed; the native app is given no query at all.
    try std.testing.expectError(error.UiQueryFailed, native_app.uiQuery(std.testing.allocator));
}
