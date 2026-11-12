//
// Reading a process environment variable from the thread's environment, or from the operating system when the thread has none.
//

const std = @import("std");
const utils = @import("utils");

//
// The value of the named variable, copied into the arena, or null when it is not set. A thread whose environment was set with
// utils.process_env (a test, or the core's main thread) is read from there; a native app's thread, which has none, reads the
// operating system's own environment.
//
pub fn get(arena: std.mem.Allocator, name: []const u8) !?[]const u8 {
    if (utils.process_env.getEnvironMap()) |map| {
        return map.get(name);
    }
    const name_z = try arena.dupeZ(u8, name);
    const value = std.c.getenv(name_z.ptr) orelse return null;
    const copied = try arena.dupe(u8, std.mem.span(value));
    return copied;
}
