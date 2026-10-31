const std = @import("std");

//
// Has the native app do something only it can, by the method's name, and gives back its result as JSON text. Whoever owns the
// connection to the native app makes one and hands it down to the code that needs it, so no code reaches for it through a global. A
// platform with no such native app has none to hand down, and the code that needs one fails loudly.
//
pub const INativeCaller = struct {
    // Pointer to the implementation.
    ptr: *anyopaque,

    // Has the native app do what the method names, with the calling thread's Io. The request and the result are JSON text, and the
    // result is allocated with the allocator. An error is the native app's reason, or why the call could not reach it.
    request: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) anyerror![]const u8,

    //
    // Has the native app do what the method names and returns its result.
    //
    pub fn call(self: INativeCaller, io: std.Io, allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) anyerror![]const u8 {
        return self.request(self.ptr, io, allocator, method, request_json);
    }
};
