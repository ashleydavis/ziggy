const std = @import("std");
const ziggy = @import("ziggy");

const TimerList = ziggy.timers.TimerList;
const Timers = ziggy.timers.Timers;

//
// What the timers of a test record: the names of the callbacks that ran, in order, allocated with the allocator the callbacks are
// given, which is the test's.
//
const Record = struct {
    // The names, one letter each.
    ran: std.ArrayList(u8) = .empty,

    fn deinit(self: *Record) void {
        self.ran.deinit(std.testing.allocator);
    }
};

//
// A callback of a test: records its name, which is the address it was given in the record's list of names.
//
fn Callback(comptime name: u8) type {
    return struct {
        fn run(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, services: ?*const anyopaque) void {
            _ = io;
            _ = timers;
            _ = services;
            const record: *Record = @ptrCast(@alignCast(context.?));
            record.ran.append(allocator, name) catch @panic("out of memory recording a timer");
        }

        fn timer(record: *Record) ziggy.timers.TimerCallback {
            return .{
                .context = record,
                .function = run,
            };
        }
    };
}

//
// Runs the due timers until the time given has passed, sleeping until the next one is due.
//
fn runFor(timers: *TimerList, milliseconds: i64) void {
    const until = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .raw = .fromMilliseconds(milliseconds),
        .clock = .awake,
    });
    while (until.durationFromNow(std.testing.io).raw.nanoseconds > 0) {
        timers.runDue(std.testing.io, std.testing.allocator, null);
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    timers.runDue(std.testing.io, std.testing.allocator, null);
}

test "a timeout runs once, after its time, and is then no longer set" {
    const io = std.testing.io;
    var timers = TimerList.init();
    var record: Record = .{};
    defer record.deinit();
    const id = try timers.setTimeout(io, Callback('a').timer(&record), 30);
    timers.runDue(io, std.testing.allocator, null);
    try std.testing.expectEqualStrings("", record.ran.items);
    try std.testing.expect(timers.isSet(id));
    runFor(&timers, 60);
    try std.testing.expectEqualStrings("a", record.ran.items);
    try std.testing.expect(!timers.isSet(id));
    try std.testing.expectEqual(@as(usize, 0), timers.count);
}

test "clearTimeout stops a timeout before it runs" {
    const io = std.testing.io;
    var timers = TimerList.init();
    var record: Record = .{};
    defer record.deinit();
    const id = try timers.setTimeout(io, Callback('a').timer(&record), 10);
    timers.clearTimeout(id);
    runFor(&timers, 40);
    try std.testing.expectEqualStrings("", record.ran.items);
    // Clearing what is no longer set changes nothing.
    timers.clearTimeout(id);
    timers.clearTimeout(12345);
}

test "an interval runs every time its time passes, until clearInterval stops it" {
    const io = std.testing.io;
    var timers = TimerList.init();
    var record: Record = .{};
    defer record.deinit();
    const id = try timers.setInterval(io, Callback('i').timer(&record), 10);
    runFor(&timers, 75);
    const runs = record.ran.items.len;
    try std.testing.expect(runs >= 3);
    try std.testing.expect(timers.isSet(id));
    timers.clearInterval(id);
    runFor(&timers, 40);
    try std.testing.expectEqual(runs, record.ran.items.len);
    try std.testing.expect(!timers.isSet(id));
}

test "due timers run the earliest first, and nextTimeout is the earliest one's time, or none when no timer is set" {
    const io = std.testing.io;
    var timers = TimerList.init();
    var record: Record = .{};
    defer record.deinit();
    try std.testing.expect(timers.nextTimeout() == .none);
    _ = try timers.setTimeout(io, Callback('b').timer(&record), 20);
    _ = try timers.setTimeout(io, Callback('a').timer(&record), 5);
    const next = timers.nextTimeout();
    try std.testing.expect(next == .deadline);
    const remaining = next.deadline.durationFromNow(io).raw.toMilliseconds();
    try std.testing.expect(remaining <= 5);
    io.sleep(.fromMilliseconds(30), .awake) catch {};
    timers.runDue(io, std.testing.allocator, null);
    try std.testing.expectEqualStrings("ab", record.ran.items);
}

//
// A callback that sets a timeout of its own, on the timers it is given, when it runs.
//
fn setAnother(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, services: ?*const anyopaque) void {
    _ = services;
    const record: *Record = @ptrCast(@alignCast(context.?));
    record.ran.append(allocator, 's') catch @panic("out of memory recording a timer");
    _ = timers.setTimeout(io, Callback('n').timer(record), 0) catch @panic("too many timers");
}

test "a callback can set a timer, which runs later, not in the same run" {
    const io = std.testing.io;
    var timers = TimerList.init();
    var record: Record = .{};
    defer record.deinit();
    _ = try timers.setTimeout(io, .{
        .context = &record,
        .function = setAnother,
    }, 1);
    io.sleep(.fromMilliseconds(5), .awake) catch {};
    timers.runDue(io, std.testing.allocator, null);
    try std.testing.expectEqualStrings("s", record.ran.items);
    runFor(&timers, 40);
    try std.testing.expectEqualStrings("sn", record.ran.items);
}

//
// A callback that records the services it was given, as the letter 'y' when they are the ones the test passed and 'n' otherwise.
//
fn recordServices(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, services: ?*const anyopaque) void {
    _ = io;
    _ = timers;
    const record: *Record = @ptrCast(@alignCast(context.?));
    const expected: *const u32 = @ptrCast(@alignCast(services.?));
    record.ran.append(allocator, if (expected.* == 42) 'y' else 'n') catch @panic("out of memory recording a timer");
}

test "a callback is given the services runDue is given" {
    const io = std.testing.io;
    var timers = TimerList.init();
    var record: Record = .{};
    defer record.deinit();
    const services: u32 = 42;
    _ = try timers.setTimeout(io, .{
        .context = &record,
        .function = recordServices,
    }, 0);
    timers.runDue(io, std.testing.allocator, &services);
    try std.testing.expectEqualStrings("y", record.ran.items);
}

test "clearAll stops every timer" {
    const io = std.testing.io;
    var timers = TimerList.init();
    var record: Record = .{};
    defer record.deinit();
    _ = try timers.setTimeout(io, Callback('a').timer(&record), 5);
    _ = try timers.setInterval(io, Callback('b').timer(&record), 5);
    try std.testing.expectEqual(@as(usize, 2), timers.count);
    timers.clearAll();
    try std.testing.expectEqual(@as(usize, 0), timers.count);
    runFor(&timers, 30);
    try std.testing.expectEqualStrings("", record.ran.items);
}

test "a thread has room for max_timers timers, and setting one more fails with TooManyTimers" {
    const io = std.testing.io;
    var timers = TimerList.init();
    var record: Record = .{};
    defer record.deinit();
    for (0..ziggy.timers.max_timers) |_| {
        _ = try timers.setTimeout(io, Callback('a').timer(&record), 60_000);
    }
    try std.testing.expectError(error.TooManyTimers, timers.setTimeout(io, Callback('a').timer(&record), 60_000));
    // Clearing one makes room again, and the others stay in the order they were set.
    timers.clearTimeout(1);
    _ = try timers.setTimeout(io, Callback('a').timer(&record), 60_000);
    try std.testing.expect(!timers.isSet(1));
    try std.testing.expect(timers.isSet(2));
}
