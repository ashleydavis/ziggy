//
// The queue that carries messages from one thread to another. Every thread Ziggy starts reads its messages from one of these, and
// the threads share nothing else: a message is a copy of JSON text. Posting copies the sender's text into memory only the queue uses,
// and taking copies it out into memory from the taking thread's own allocator, so no allocator is used by two threads. This is the
// only place in Ziggy's core where a lock appears.
//
// The queue keeps no Io of its own: each call is given the Io of the thread that makes it, so no thread uses another thread's Io.
//

const std = @import("std");

//
// One message: who sent it and its JSON text.
//
pub const Message = struct {
    // Who sent the message, as the thread reading the queue numbers its senders (a worker's id, for one). Zero when the reader has
    // only one sender or does not care which sent it.
    from: u32,
    // The JSON text. A message taken from a queue holds a copy allocated with the allocator the taking thread gave, which it frees.
    text: []u8,
    // Where a reply to this message goes, for a sender that is not a thread the reader knows by number (a remote control connection,
    // for one), or null.
    reply_to: ?*MessageQueue = null,
};

//
// A queue of messages, first in first out, that any number of threads post to and one thread takes from. It must stay where it is
// while it is used.
//
pub const MessageQueue = struct {
    // Guards the fields below.
    mutex: std.Io.Mutex,
    // Allocates the queue's copies of the messages and its list, only with the lock held. No thread uses it but through the queue.
    store: std.heap.DebugAllocator(.{
        .thread_safe = false,
    }),
    // The messages not taken yet. The first `head` of them have been taken already.
    items: std.ArrayList(Message),
    // The index of the next message to take.
    head: usize,
    // Set once the queue is closed: nothing more is posted to it, and a wait for a message returns at once when it is empty.
    closed: bool,
    // Changed whenever a message is posted or the queue is closed, so a thread waiting for a message wakes. It is the futex word
    // the wait sleeps on.
    changes: std.atomic.Value(u32),

    //
    // Makes an empty queue.
    //
    pub fn init() MessageQueue {
        return .{
            .mutex = .init,
            .store = .init,
            .items = .empty,
            .head = 0,
            .closed = false,
            .changes = .init(0),
        };
    }

    //
    // Frees the messages nobody took and the queue's own memory. No thread may use the queue afterwards.
    //
    pub fn deinit(self: *MessageQueue) void {
        const store = self.store.allocator();
        for (self.items.items[self.head..]) |message| {
            store.free(message.text);
        }
        self.items.deinit(store);
        _ = self.store.deinit();
    }

    //
    // Posts a copy of the JSON text, from the sender numbered `from`, with the Io of the calling thread. A message posted to a closed
    // queue is dropped.
    //
    pub fn post(self: *MessageQueue, io: std.Io, from: u32, text: []const u8) !void {
        try self.postReplyTo(io, from, text, null);
    }

    //
    // Posts a copy of the JSON text, from the sender numbered `from`, with the queue a reply goes to, with the Io of the calling
    // thread.
    //
    pub fn postReplyTo(self: *MessageQueue, io: std.Io, from: u32, text: []const u8, reply_to: ?*MessageQueue) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) {
            return;
        }
        const store = self.store.allocator();
        const copy = try store.dupe(u8, text);
        errdefer store.free(copy);
        try self.items.append(store, .{
            .from = from,
            .text = copy,
            .reply_to = reply_to,
        });
        self.wake(io);
    }

    //
    // Takes the next message, waiting for one until the timeout passes, with the Io of the calling thread. The text is copied with
    // the allocator, the calling thread's own, which the caller frees it with. Returns null when the timeout passed with no message,
    // or when the queue is closed and empty. `.none` waits for as long as it takes.
    //
    pub fn take(self: *MessageQueue, io: std.Io, allocator: std.mem.Allocator, timeout: std.Io.Timeout) ?Message {
        const deadline = timeout.toDeadline(io);
        while (true) {
            self.mutex.lockUncancelable(io);
            if (self.takeLocked(allocator)) |message| {
                self.mutex.unlock(io);
                return message;
            }
            if (self.closed) {
                self.mutex.unlock(io);
                return null;
            }
            const seen = self.changes.load(.acquire);
            self.mutex.unlock(io);
            if (deadline != .none and deadline.toDurationFromNow(io).?.raw.nanoseconds <= 0) {
                return null;
            }
            io.futexWaitTimeout(u32, &self.changes.raw, seen, deadline) catch |err| switch (err) {
                error.Canceled => @panic("a wait for a message was cancelled"),
            };
        }
    }

    //
    // Takes the next message without waiting, with the Io of the calling thread, or returns null when there is none. The text is
    // copied with the allocator, as `take` does.
    //
    pub fn tryTake(self: *MessageQueue, io: std.Io, allocator: std.mem.Allocator) ?Message {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.takeLocked(allocator);
    }

    //
    // Closes the queue, with the Io of the calling thread: messages posted from now on are dropped, and a thread waiting on an empty
    // queue stops waiting. The messages already in it can still be taken.
    //
    pub fn close(self: *MessageQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closed = true;
        self.wake(io);
    }

    //
    // Whether the queue has been closed, with the Io of the calling thread.
    //
    pub fn isClosed(self: *MessageQueue, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.closed;
    }

    //
    // Takes the next message with the lock held, copying its text with the taking thread's allocator and freeing the queue's copy, or
    // returns null when there is none.
    //
    fn takeLocked(self: *MessageQueue, allocator: std.mem.Allocator) ?Message {
        if (self.head == self.items.items.len) {
            return null;
        }
        const queued = self.items.items[self.head];
        const text = allocator.dupe(u8, queued.text) catch @panic("out of memory taking a message");
        self.store.allocator().free(queued.text);
        self.head += 1;
        if (self.head == self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        }
        return .{
            .from = queued.from,
            .text = text,
            .reply_to = queued.reply_to,
        };
    }

    //
    // Wakes every thread waiting for a message, with the lock held.
    //
    fn wake(self: *MessageQueue, io: std.Io) void {
        _ = self.changes.fetchAdd(1, .release);
        io.futexWake(u32, &self.changes.raw, std.math.maxInt(u32));
    }
};
