//
// A thread's timers: setTimeout, clearTimeout, setInterval and clearInterval, as JavaScript has them. Their callbacks run on the
// thread that set them, which waits for its next message only until the next timer is due (see core.zig for the main thread and
// worker.zig for a worker). A timer is set and cleared only on the thread whose timers they are.
//
// Handlers reach a thread's timers through `Timers`, an interface as `std.Io` is, and never see the `TimerList` behind it. A thread's
// timers are kept in space of their own, so setting one needs no allocator: a handler may set a timer that outlives the memory it was
// given.
//

const std = @import("std");

//
// Identifies a timer, for clearing it. Ids are never reused.
//
pub const TimerId = u64;

//
// The most timers a thread may have set at once.
//
pub const max_timers = 256;

//
// What a timer runs when it is due, on the thread that set it, with that thread's Io, allocator and timers and the services of the
// thread: on the main thread its handler services (see `ziggy.core.handlerServicesOf`), and on a worker the services of the task that
// is running (see `ziggy.task_runner.taskServicesOf`).
//
pub const TimerCallback = struct {
    // The callback's own pointer, passed back on every call.
    context: ?*anyopaque,
    // Runs the callback.
    function: *const fn (context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, services: ?*const anyopaque) void,
};

//
// One timer.
//
const Timer = struct {
    // The timer's id.
    id: TimerId,
    // When it is next due, on the awake clock.
    due: std.Io.Clock.Timestamp,
    // For an interval, how long between runs. Null for a timeout, which runs once.
    interval: ?std.Io.Duration,
    // What it runs.
    callback: TimerCallback,
};

//
// The timers of one thread, as a handler reaches them: an interface to the thread's timers that hides how they are kept. It is a small
// value that may be copied and kept, and it is valid on the thread that was given it: on the main thread until it stops, and on a
// worker until the task it was given to ends.
//
pub const Timers = struct {
    // The implementation's own pointer, passed back on every call.
    ptr: *anyopaque,
    // The implementation's functions.
    vtable: *const VTable,

    //
    // The functions behind the interface.
    //
    pub const VTable = struct {
        // Sets a timer that runs once, or every time the milliseconds pass when `repeat` is true, and gives its id.
        set: *const fn (ptr: *anyopaque, io: std.Io, callback: TimerCallback, milliseconds: u64, repeat: bool) anyerror!TimerId,
        // Clears a timer.
        clear: *const fn (ptr: *anyopaque, id: TimerId) void,
        // How long the thread may wait for its next message: until the next timer is due.
        nextTimeout: *const fn (ptr: *anyopaque) std.Io.Timeout,
        // Runs every timer that is due.
        runDue: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, services: ?*const anyopaque) void,
        // Whether the timer with the id is set: it has not been cleared and, for a timeout, has not run.
        isSet: *const fn (ptr: *anyopaque, id: TimerId) bool,
    };

    //
    // How long the thread may wait for its next message: until the next timer is due, or for as long as it takes when there is none.
    //
    pub fn nextTimeout(self: Timers) std.Io.Timeout {
        return self.vtable.nextTimeout(self.ptr);
    }

    //
    // Runs every timer that is due, with the thread's Io, allocator and services (see TimerCallback).
    //
    pub fn runDue(self: Timers, io: std.Io, allocator: std.mem.Allocator, services: ?*const anyopaque) void {
        self.vtable.runDue(self.ptr, io, allocator, services);
    }

    //
    // Whether the timer with the id is set: it has not been cleared and, for a timeout, has not run.
    //
    pub fn isSet(self: Timers, id: TimerId) bool {
        return self.vtable.isSet(self.ptr, id);
    }

    //
    // Runs the callback once, after the milliseconds given, as JavaScript's setTimeout does, and returns the timer's id. `io` is the
    // calling thread's.
    //
    pub fn setTimeout(self: Timers, io: std.Io, callback: TimerCallback, milliseconds: u64) !TimerId {
        return try self.vtable.set(self.ptr, io, callback, milliseconds, false);
    }

    //
    // Stops a timeout before it runs, as JavaScript's clearTimeout does.
    //
    pub fn clearTimeout(self: Timers, id: TimerId) void {
        self.vtable.clear(self.ptr, id);
    }

    //
    // Runs the callback every time the milliseconds given pass, until it is cleared, as JavaScript's setInterval does, and returns the
    // timer's id. `io` is the calling thread's.
    //
    pub fn setInterval(self: Timers, io: std.Io, callback: TimerCallback, milliseconds: u64) !TimerId {
        return try self.vtable.set(self.ptr, io, callback, milliseconds, true);
    }

    //
    // Stops an interval, as JavaScript's clearInterval does.
    //
    pub fn clearInterval(self: Timers, id: TimerId) void {
        self.vtable.clear(self.ptr, id);
    }
};

//
// The timers of one thread, as the thread keeps them: a variable of the function the thread starts with.
//
pub const TimerList = struct {
    // The timers not cleared yet, in the order they were set: the first `count` of these.
    timers: [max_timers]Timer,
    // How many timers are set.
    count: usize,
    // The id of the next timer.
    next_id: TimerId,

    //
    // Makes an empty set of timers.
    //
    pub fn init() TimerList {
        return .{
            .timers = undefined,
            .count = 0,
            .next_id = 1,
        };
    }

    //
    // The interface handlers reach these timers through. It is valid for as long as the list is.
    //
    pub fn interface(self: *TimerList) Timers {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: Timers.VTable = .{
        .set = setErased,
        .clear = clearErased,
        .nextTimeout = nextTimeoutErased,
        .runDue = runDueErased,
        .isSet = isSetErased,
    };

    //
    // The interface's nextTimeout.
    //
    fn nextTimeoutErased(ptr: *anyopaque) std.Io.Timeout {
        const self: *TimerList = @ptrCast(@alignCast(ptr));
        return self.nextTimeout();
    }

    //
    // The interface's runDue.
    //
    fn runDueErased(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, services: ?*const anyopaque) void {
        const self: *TimerList = @ptrCast(@alignCast(ptr));
        self.runDue(io, allocator, services);
    }

    //
    // The interface's isSet.
    //
    fn isSetErased(ptr: *anyopaque, id: TimerId) bool {
        const self: *TimerList = @ptrCast(@alignCast(ptr));
        return self.isSet(id);
    }

    //
    // The interface's set: a timeout or an interval on this list.
    //
    fn setErased(ptr: *anyopaque, io: std.Io, callback: TimerCallback, milliseconds: u64, repeat: bool) anyerror!TimerId {
        const self: *TimerList = @ptrCast(@alignCast(ptr));
        if (repeat) {
            return try self.setInterval(io, callback, milliseconds);
        }
        return try self.setTimeout(io, callback, milliseconds);
    }

    //
    // The interface's clear.
    //
    fn clearErased(ptr: *anyopaque, id: TimerId) void {
        const self: *TimerList = @ptrCast(@alignCast(ptr));
        self.remove(id);
    }

    //
    // Runs the callback once, after the milliseconds given, and returns the timer's id. `io` is the thread's. Fails with TooManyTimers
    // when `max_timers` are set already.
    //
    pub fn setTimeout(self: *TimerList, io: std.Io, callback: TimerCallback, milliseconds: u64) !TimerId {
        return self.add(io, callback, milliseconds, null);
    }

    //
    // Runs the callback every time the milliseconds given pass, until the timer is cleared, and returns the timer's id. `io` is the
    // thread's. Fails with TooManyTimers when `max_timers` are set already.
    //
    pub fn setInterval(self: *TimerList, io: std.Io, callback: TimerCallback, milliseconds: u64) !TimerId {
        return self.add(io, callback, milliseconds, .fromMilliseconds(@intCast(milliseconds)));
    }

    //
    // Stops a timeout before it runs. An id that is not a timer's, or a timer that has run or been cleared, changes nothing.
    //
    pub fn clearTimeout(self: *TimerList, id: TimerId) void {
        self.remove(id);
    }

    //
    // Stops an interval. An id that is not a timer's, or a timer that has been cleared, changes nothing.
    //
    pub fn clearInterval(self: *TimerList, id: TimerId) void {
        self.remove(id);
    }

    //
    // Stops every timer.
    //
    pub fn clearAll(self: *TimerList) void {
        self.count = 0;
    }

    //
    // The timers set and not cleared, counting a timeout only until it has run.
    //
    fn set(self: *TimerList) []Timer {
        return self.timers[0..self.count];
    }

    //
    // Whether the timer with the id is set: it has not been cleared and, for a timeout, has not run.
    //
    pub fn isSet(self: *TimerList, id: TimerId) bool {
        for (self.set()) |timer| {
            if (timer.id == id) {
                return true;
            }
        }
        return false;
    }

    //
    // How long the thread may wait for its next message: until the next timer is due, or for as long as it takes when there is none.
    //
    pub fn nextTimeout(self: *TimerList) std.Io.Timeout {
        var earliest: ?std.Io.Clock.Timestamp = null;
        for (self.set()) |timer| {
            if (earliest == null or timer.due.compare(.lt, earliest.?)) {
                earliest = timer.due;
            }
        }
        const due = earliest orelse {
            return .none;
        };
        return .{
            .deadline = due,
        };
    }

    //
    // Runs every timer that is due, the earliest first. A timeout is removed before its callback runs, and an interval is moved to its
    // next time. A callback may set and clear timers, and a timer set by a callback runs on a later call at the soonest. `io` and the
    // allocator are the thread's, which each callback is given with these timers and the services given.
    //
    pub fn runDue(self: *TimerList, io: std.Io, allocator: std.mem.Allocator, services: ?*const anyopaque) void {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        while (true) {
            var due_index: ?usize = null;
            for (self.set(), 0..) |timer, index| {
                if (timer.due.compare(.gt, now)) {
                    continue;
                }
                if (due_index == null or timer.due.compare(.lt, self.timers[due_index.?].due)) {
                    due_index = index;
                }
            }
            const index = due_index orelse {
                return;
            };
            const timer = self.timers[index];
            if (timer.interval) |interval| {
                self.timers[index].due = timer.due.addDuration(.{
                    .raw = interval,
                    .clock = .awake,
                });
                if (self.timers[index].due.compare(.lte, now)) {
                    self.timers[index].due = now.addDuration(.{
                        .raw = interval,
                        .clock = .awake,
                    });
                }
            }
            else {
                self.removeAt(index);
            }
            timer.callback.function(timer.callback.context, io, allocator, self.interface(), services);
        }
    }

    //
    // Adds a timer due after the milliseconds given.
    //
    fn add(self: *TimerList, io: std.Io, callback: TimerCallback, milliseconds: u64, interval: ?std.Io.Duration) !TimerId {
        if (self.count == max_timers) {
            return error.TooManyTimers;
        }
        const id = self.next_id;
        self.next_id += 1;
        self.timers[self.count] = .{
            .id = id,
            .due = std.Io.Clock.Timestamp.fromNow(io, .{
                .raw = .fromMilliseconds(@intCast(milliseconds)),
                .clock = .awake,
            }),
            .interval = interval,
            .callback = callback,
        };
        self.count += 1;
        return id;
    }

    //
    // Removes the timer with the id, if there is one.
    //
    fn remove(self: *TimerList, id: TimerId) void {
        for (self.set(), 0..) |timer, index| {
            if (timer.id == id) {
                self.removeAt(index);
                return;
            }
        }
    }

    //
    // Removes the timer at the index, keeping the others in the order they were set.
    //
    fn removeAt(self: *TimerList, index: usize) void {
        std.mem.copyForwards(Timer, self.timers[index .. self.count - 1], self.timers[index + 1 .. self.count]);
        self.count -= 1;
    }
};
