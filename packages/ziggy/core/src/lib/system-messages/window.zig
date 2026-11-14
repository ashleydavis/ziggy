//
// The system message of new windows: new-window, which window.ziggy.newWindow sends to start another window of the app.
//

const std = @import("std");
const services_lib = @import("../services.zig");

//
// The data of new-window.
//
pub const NewWindowRequest = struct {
    // The arguments of the new window, after the program's name.
    arguments: []const []const u8,
};

//
// The message response to new-window, an empty object.
//
pub const DoneResponse = struct {};

//
// Starts another window of the app through the handler services (see HandlerServices.new_window), so window.ziggy.newWindow and the
// backend's new_window start it the same way. Its error is this message's error.
//
pub fn new_window(services: services_lib.HandlerServices, io: std.Io, allocator: std.mem.Allocator, request: NewWindowRequest) !DoneResponse {
    try services.new_window(io, allocator, request.arguments);
    return .{};
}
