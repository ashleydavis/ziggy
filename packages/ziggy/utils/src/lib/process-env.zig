const std = @import("std");

//
// The process environment. Zig 0.16 hands the environment to `main` (std.process.Init.environ_map) instead of making it
// global, so `main` calls setEnvironMap once and library code reads variables with getEnv.
// Each thread has its own: the thread that sets it is the one that reads it. A thread Ziggy starts (the core's main thread, a
// worker) is given a copy of the environment of the thread that started it, and sets it as its own.
//

//
// The environment of the calling thread, or null when setEnvironMap has not been called on it.
//
threadlocal var environ_map: ?*const std.process.Environ.Map = null;

//
// Sets the environment getEnv reads on the calling thread (call from `main` with `init.environ_map`, or from tests).
//
pub fn setEnvironMap(map: ?*const std.process.Environ.Map) void {
    environ_map = map;
}

//
// Equivalent of `process.env[name]`: the value of an environment variable, or null when it is not set
// (or when no environment has been set with setEnvironMap on the calling thread).
//
pub fn getEnv(name: []const u8) ?[]const u8 {
    const map = environ_map orelse return null;
    return map.get(name);
}

//
// Gets the environment set with setEnvironMap on the calling thread (null when none), for passing to child processes
// so they inherit `process.env`.
//
pub fn getEnvironMap() ?*const std.process.Environ.Map {
    return environ_map;
}

//
// Copies an environment into a new one allocated with the allocator, for a thread that is to have an environment of its own.
//
pub fn copyEnvironMap(allocator: std.mem.Allocator, map: *const std.process.Environ.Map) !std.process.Environ.Map {
    var copy = std.process.Environ.Map.init(allocator);
    errdefer copy.deinit();
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        try copy.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return copy;
}
