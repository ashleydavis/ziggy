//
// Checks how a native app's command line gives up --remote-control: the address is taken, the option and its address are left out
// of what the app sees, and a command line without it passes through unchanged.
//

const std = @import("std");
const ziggy = @import("ziggy");

const take = ziggy.remote_control_arguments.take;

test "--remote-control and its address are taken out, and the rest pass through in order" {
    const taken = try take(std.testing.allocator, &.{ "app", "--open", "a.txt", "--remote-control", "127.0.0.1:4001", "-geometry=800x600" });
    defer std.testing.allocator.free(taken.arguments);
    try std.testing.expectEqualStrings("127.0.0.1:4001", taken.remote_control.?);
    try std.testing.expectEqual(@as(usize, 4), taken.arguments.len);
    try std.testing.expectEqualStrings("app", taken.arguments[0]);
    try std.testing.expectEqualStrings("--open", taken.arguments[1]);
    try std.testing.expectEqualStrings("a.txt", taken.arguments[2]);
    try std.testing.expectEqualStrings("-geometry=800x600", taken.arguments[3]);
}

test "a command line without --remote-control passes through unchanged" {
    const command_line = [_][:0]const u8{ "app", "--open", "a.txt" };
    const taken = try take(std.testing.allocator, &command_line);
    defer std.testing.allocator.free(taken.arguments);
    try std.testing.expect(taken.remote_control == null);
    try std.testing.expectEqual(command_line.len, taken.arguments.len);
    for (command_line, taken.arguments) |given, passed| {
        try std.testing.expectEqualStrings(given, passed);
    }
}

test "--remote-control with no address after it is an error" {
    try std.testing.expectError(error.RemoteControlAddressMissing, take(std.testing.allocator, &.{ "app", "--remote-control" }));
}

test "--remote-control given twice is an error" {
    try std.testing.expectError(error.RemoteControlGivenTwice, take(std.testing.allocator, &.{ "app", "--remote-control", "127.0.0.1:1", "--remote-control", "127.0.0.1:2" }));
}

test "the program's name is never taken as the option" {
    const taken = try take(std.testing.allocator, &.{"--remote-control"});
    defer std.testing.allocator.free(taken.arguments);
    try std.testing.expect(taken.remote_control == null);
    try std.testing.expectEqual(@as(usize, 1), taken.arguments.len);
}

test "running out of memory fails cleanly" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, takeAndFree, .{});
}

//
// Takes the option from a command line and frees what it made, for the allocation failure test.
//
fn takeAndFree(allocator: std.mem.Allocator) !void {
    const taken = try take(allocator, &.{ "app", "--remote-control", "127.0.0.1:4001", "x" });
    allocator.free(taken.arguments);
}
