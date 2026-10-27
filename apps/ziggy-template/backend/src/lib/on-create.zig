//
// What the template does when its main thread starts.
//

const std = @import("std");
const ziggy = @import("ziggy");

const ILogOptions = ziggy.task_queue.utils.log.ILogOptions;

//
// Configures the log once, as early as the app can, from the options on the template's command line.
//
pub fn onCreate(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) anyerror!void {
    _ = timers;
    _ = io;
    _ = allocator;
    try services.configureLog(logOptions(arguments));
}

//
// The log options on the command line: --verbose, --debug and --tools each turn on their lines. Every other argument is left to
// whatever else reads the command line.
//
pub fn logOptions(arguments: []const []const u8) ILogOptions {
    var options: ILogOptions = .{
        .verbose = false,
        .debug = false,
        .tools = false,
    };
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, "--verbose")) {
            options.verbose = true;
        }
        else if (std.mem.eql(u8, argument, "--debug")) {
            options.debug = true;
        }
        else if (std.mem.eql(u8, argument, "--tools")) {
            options.tools = true;
        }
    }
    return options;
}
