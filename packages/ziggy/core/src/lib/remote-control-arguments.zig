//
// Takes `--remote-control <host:port>` out of a native app's command line. The native app gives the address to the core as the
// configuration's remote_control and passes the rest on, so an app's own argument handling never sees the option. The Linux and
// Windows native apps call it before anything else reads the command line. It is one file of the core that those native apps
// import on its own, because they reach the rest of the core only through ziggy.h.
//

const std = @import("std");

//
// The command line with the option taken out.
//
pub const RemoteControlArguments = struct {
    // The address after --remote-control, or null when the command line has none.
    remote_control: ?[:0]const u8,
    // The command line without --remote-control and its address, the program's name first, allocated with the allocator given to
    // take. The strings are the command line's own.
    arguments: []const [:0]const u8,
};

//
// Takes --remote-control and the address after it out of the command line, which starts with the program's name. Fails with
// RemoteControlAddressMissing when --remote-control is the last argument, and with RemoteControlGivenTwice when it is given more
// than once. The caller frees `arguments` with the allocator.
//
pub fn take(allocator: std.mem.Allocator, command_line: []const [:0]const u8) !RemoteControlArguments {
    var remote_control: ?[:0]const u8 = null;
    var arguments: std.ArrayList([:0]const u8) = try .initCapacity(allocator, command_line.len);
    errdefer arguments.deinit(allocator);
    var index: usize = 0;
    while (index < command_line.len) : (index += 1) {
        const argument = command_line[index];
        if (index == 0 or !std.mem.eql(u8, argument, "--remote-control")) {
            arguments.appendAssumeCapacity(argument);
            continue;
        }
        if (index + 1 >= command_line.len) {
            return error.RemoteControlAddressMissing;
        }
        if (remote_control != null) {
            return error.RemoteControlGivenTwice;
        }
        remote_control = command_line[index + 1];
        index += 1;
    }
    std.debug.assert(arguments.items.len <= command_line.len);
    if (remote_control != null) {
        std.debug.assert(arguments.items.len + 2 == command_line.len);
    }
    return .{
        .remote_control = remote_control,
        .arguments = try arguments.toOwnedSlice(allocator),
    };
}
