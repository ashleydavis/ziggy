//
// A registry of message handlers by name. The core keeps two: one of app messages, which App fills when the app starts and
// Core.registerMessage adds to while it runs, and one of system messages, which the parts of Ziggy fill (see system-messages.zig).
// Handlers can be registered at any point, from any thread, while messages are being handled. Each handler is wrapped by
// handlers.zig, so app and system handlers take the same forms.
//

const std = @import("std");
const handlers = @import("handlers.zig");

//
// The handlers of one kind of message, by name.
//
pub const Registry = struct {
    // Allocates the table and the copies of the names.
    allocator: std.mem.Allocator,
    // The Io the lock waits with.
    io: std.Io,
    // Which kind of message the registry holds, "app" or "system", for the text of a refused registration.
    kind: []const u8,
    // The handler of each registered name. The names are copies the registry owns.
    entries: std.StringHashMapUnmanaged(handlers.WrappedHandler),
    // Guards entries, which a registration from any thread changes while messages are being looked up.
    mutex: std.Io.Mutex,

    //
    // Makes an empty registry of the kind of message named.
    //
    pub fn init(allocator: std.mem.Allocator, io: std.Io, kind: []const u8) Registry {
        return .{
            .allocator = allocator,
            .io = io,
            .kind = kind,
            .entries = .empty,
            .mutex = .init,
        };
    }

    //
    // Releases the table and the names.
    //
    pub fn deinit(self: *Registry) void {
        var iterator = self.entries.keyIterator();
        while (iterator.next()) |name| {
            self.allocator.free(name.*);
        }
        self.entries.deinit(self.allocator);
    }

    //
    // Registers a handler, in any of the forms handlers.zig describes, under the message name, which a compile error about the
    // handler names. A name registered already is the error DuplicateMessage, and the name is printed.
    //
    pub fn register(self: *Registry, comptime name: []const u8, comptime handler: anytype) !void {
        try self.registerWrapped(name, handlers.wrapNamed("the message \"" ++ name ++ "\"", handler));
    }

    //
    // Registers a handler handlers.zig has wrapped already under the message name. A name registered already is the error
    // DuplicateMessage, and the name is printed.
    //
    pub fn registerWrapped(self: *Registry, name: []const u8, handler: handlers.WrappedHandler) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = try self.entries.getOrPut(self.allocator, owned_name);
        if (entry.found_existing) {
            std.debug.print("Ziggy: the {s} message \"{s}\" is registered already\n", .{ self.kind, name });
            return error.DuplicateMessage;
        }
        entry.value_ptr.* = handler;
    }

    //
    // The handler registered under the message name, or null when there is none.
    //
    pub fn find(self: *Registry, name: []const u8) ?handlers.WrappedHandler {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.entries.get(name);
    }
};
