//
// The allocator a thread makes for itself when it starts. No two threads use the same allocator: each thread Ziggy starts makes one of
// these on its own thread, as it makes its own Io, and everything it allocates comes from it. What reaches another thread is a copy,
// made by the message queue (see message-queue.zig). It has no lock, because only the thread that made it uses it.
//

const std = @import("std");

//
// One thread's allocator. It must stay where it is while the thread uses it.
//
pub const ThreadAllocator = struct {
    // The allocator, which reports every allocation its thread never freed when the thread ends.
    debug: std.heap.DebugAllocator(.{
        .thread_safe = false,
    }),

    //
    // A thread's allocator with nothing allocated.
    //
    pub const init: ThreadAllocator = .{
        .debug = .init,
    };

    //
    // The allocator.
    //
    pub fn allocator(self: *ThreadAllocator) std.mem.Allocator {
        return self.debug.allocator();
    }

    //
    // Releases the allocator's memory, logging as an error each allocation its thread never freed. The thread calls it last, as it
    // ends.
    //
    pub fn deinit(self: *ThreadAllocator) void {
        _ = self.debug.deinit();
    }
};
