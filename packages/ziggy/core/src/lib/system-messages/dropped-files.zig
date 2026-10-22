//
// The dropped files' system message: get-dropped-paths, which the frontend script sends for the paths of the files last dropped
// on the window.
//

const std = @import("std");
const json = @import("../json.zig");
const core_lib = @import("../core.zig");
const message_registry = @import("../message-registry.zig");

const Core = core_lib.Core;

//
// Registers the dropped files' system message. The core calls it once it keeps the dropped files.
//
pub fn register(registry: *message_registry.Registry) !void {
    try registry.register("get-dropped-paths", getDroppedPathsHandler);
}

//
// The data of get-dropped-paths, which has none.
//
const GetDroppedPathsRequest = struct {};

//
// Handles the frontend's request for the paths of the files in the last drop: an array of strings, empty when nothing was dropped.
//
fn getDroppedPathsHandler(core: *Core, arena: std.mem.Allocator, request: GetDroppedPathsRequest) !json.Raw {
    _ = request;
    return .{
        .text = try core.dropped.pathsJson(core.io(), arena),
    };
}
