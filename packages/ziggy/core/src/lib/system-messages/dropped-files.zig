//
// The dropped files' system message: get-dropped-paths, which the frontend script sends for the paths of the files last dropped
// on the window.
//

const std = @import("std");
const json = @import("../json.zig");
const dropped_files = @import("../dropped-files.zig");

//
// Handles the frontend's request for the paths of the files in the last drop: an array of strings, empty when nothing was dropped.
//
pub fn getDroppedPaths(dropped: *dropped_files.DroppedFiles, allocator: std.mem.Allocator) !json.Raw {
    return .{
        .text = try dropped.pathsJson(allocator),
    };
}
