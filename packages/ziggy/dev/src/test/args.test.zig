const std = @import("std");
const args = @import("../lib/args.zig");

test "the dev host's options are read, and the port defaults to one the system chooses" {
    const options = try args.parseDevHostOptions(&.{ "--data-dir", "data", "--port-file", "port.txt", "--ui-port", "5173" });
    try std.testing.expectEqual(@as(u16, 0), options.port);
    try std.testing.expectEqualStrings("data", options.data_dir);
    try std.testing.expectEqualStrings("port.txt", options.port_file.?);
    const with_port = try args.parseDevHostOptions(&.{ "--port", "4000", "--data-dir", "data", "--ui-port", "5173" });
    try std.testing.expectEqual(@as(u16, 4000), with_port.port);
    try std.testing.expectEqual(@as(u16, 5173), with_port.ui_port);
    try std.testing.expect(with_port.port_file == null);
}

test "the dev host refuses a command line that is missing something or has something it does not know" {
    try std.testing.expectError(error.MissingDataDir, args.parseDevHostOptions(&.{ "--port", "1", "--ui-port", "2" }));
    try std.testing.expectError(error.MissingUiPort, args.parseDevHostOptions(&.{ "--data-dir", "d" }));
    try std.testing.expectError(error.MissingValue, args.parseDevHostOptions(&.{"--data-dir"}));
    try std.testing.expectError(error.BadPort, args.parseDevHostOptions(&.{ "--port", "70000", "--data-dir", "d", "--ui-port", "2" }));
    try std.testing.expectError(error.UnknownOption, args.parseDevHostOptions(&.{"--verbose"}));
}

test "the supervisor's options are read, from the build and from the dev server" {
    const options = try args.parseSupervisorOptions(&.{
        "--zig",       "/zig",
        "--app-dir",   "/app",
        "--ziggy-dir", "/ziggy",
        "--host-step", "my-app-dev-host",
        "--host-name", "my-app-dev-host",
        "--port",      "41234",
        "--no-open",
    });
    try std.testing.expectEqualStrings("/zig", options.zig);
    try std.testing.expectEqualStrings("/app", options.app_dir);
    try std.testing.expectEqualStrings("/ziggy", options.ziggy_dir);
    try std.testing.expectEqualStrings("my-app-dev-host", options.host_step);
    try std.testing.expectEqualStrings("my-app-dev-host", options.host_name);
    try std.testing.expectEqual(@as(u16, 41234), options.port);
    try std.testing.expect(options.no_open);
    try std.testing.expect(options.remote_control == null);
}

test "the supervisor refuses a command line that is missing what the build gives" {
    try std.testing.expectError(error.MissingHostStep, args.parseSupervisorOptions(&.{
        "--zig",       "/zig",
        "--app-dir",   "/app",
        "--ziggy-dir", "/ziggy",
        "--host-name", "h",
    }));
    try std.testing.expectError(error.UnknownOption, args.parseSupervisorOptions(&.{"--verbose"}));
    try std.testing.expectError(error.UnknownOption, args.parseSupervisorOptions(&.{"--test-hooks"}));
}

test "--remote-control is read by the dev host and the supervisor, and is absent by default" {
    const host = try args.parseDevHostOptions(&.{ "--data-dir", "data", "--ui-port", "5173", "--remote-control", "127.0.0.1:4001" });
    try std.testing.expectEqualStrings("127.0.0.1:4001", host.remote_control.?);
    const host_without = try args.parseDevHostOptions(&.{ "--data-dir", "data", "--ui-port", "5173" });
    try std.testing.expect(host_without.remote_control == null);
    const supervisor = try args.parseSupervisorOptions(&.{
        "--zig",            "/zig",
        "--app-dir",        "/app",
        "--ziggy-dir",      "/ziggy",
        "--host-step",      "h",
        "--host-name",      "h",
        "--remote-control", "127.0.0.1:4001",
    });
    try std.testing.expectEqualStrings("127.0.0.1:4001", supervisor.remote_control.?);
    try std.testing.expectError(error.MissingValue, args.parseSupervisorOptions(&.{"--remote-control"}));
    try std.testing.expectError(error.MissingValue, args.parseDevHostOptions(&.{"--remote-control"}));
}
