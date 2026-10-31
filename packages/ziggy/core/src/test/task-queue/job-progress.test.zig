const std = @import("std");
const task_queue_zig = @import("ziggy").task_queue;
const utils = @import("ziggy").utils;
const logging = @import("ziggy").log;
const types = task_queue_zig.types;
const ITaskContext = types.ITaskContext;
const sendJobProgress = task_queue_zig.job_progress.sendJobProgress;

//
// Records the events a handler sends through a task context.
//
const EventRecorder = struct {
    // Number of events sent.
    calls: usize,

    // The last event, serialized to JSON with the allocator the call was given, so it can be compared after the call returns.
    lastEvent: []const u8,


    //
    // ITaskContext.sendEvent for the recorder.
    //
    fn sendEvent(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, log: logging.ILog, event: std.json.Value) void {
        _ = log;
        _ = io;
        const self: *EventRecorder = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.lastEvent = std.json.Stringify.valueAlloc(allocator, event, .{}) catch unreachable;
    }

    //
    // ITaskContext.isCancelled for the recorder.
    //
    fn isCancelled(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) bool {
        _ = io;
        _ = allocator;
        _ = ptr;
        return false;
    }

    //
    // The ITaskContext functions of the recorder.
    //
    const vtable: ITaskContext.VTable = .{
        .sendEvent = sendEvent,
        .isCancelled = isCancelled,
    };
};

//
// The generators the test context carries (unused by sendJobProgress).
//
const Generators = struct {
    // Generates UUIDs.
    uuidGenerator: utils.random_uuid_generator.RandomUuidGenerator,

    // Provides timestamps.
    timestampProvider: utils.test_timestamp_provider.TestTimestampProvider,
};

//
// Builds a task context that records the events a handler sends through it.
//
fn makeContext(recorder: *EventRecorder, generators: *Generators) ITaskContext {
    return .{
        .uuidGenerator = generators.uuidGenerator.uuidGenerator(),
        .timestampProvider = generators.timestampProvider.timestampProvider(),
        .sessionId = "session-1",
        .taskId = "task-1",
        .maxConcurrentChildTasks = 1,
        .nativeCaller = null,
        .ptr = recorder,
        .vtable = &EventRecorder.vtable,
    };
}

test "sends the whole job with every report, so a listener that joined late learns all of it" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder: EventRecorder = .{
        .calls = 0,
        .lastEvent = "",
    };
    var generators: Generators = .{
        .uuidGenerator = .{},
        .timestampProvider = .{},
    };
    const context = makeContext(&recorder, &generators);

    try sendJobProgress(arena.allocator(), std.testing.io, console_log, context, .{
        .id = "job-1",
        .name = "Importing photos",
        .cancelSource = "session-1",
    }, 5000, "12 imported");

    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqualStrings("{\"type\":\"job-progress\",\"job\":{\"id\":\"job-1\",\"name\":\"Importing photos\",\"cancelSource\":\"session-1\"},\"startedAt\":5000,\"progressMessage\":\"12 imported\"}", recorder.lastEvent);
}

test "carries a job that has not said what it is doing yet" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder: EventRecorder = .{
        .calls = 0,
        .lastEvent = "",
    };
    var generators: Generators = .{
        .uuidGenerator = .{},
        .timestampProvider = .{},
    };
    const context = makeContext(&recorder, &generators);

    try sendJobProgress(arena.allocator(), std.testing.io, console_log, context, .{
        .id = "job-1",
        .name = "Syncing database",
    }, 5000, null);

    // (An undefined progressMessage is left out of the event.)
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqualStrings("{\"type\":\"job-progress\",\"job\":{\"id\":\"job-1\",\"name\":\"Syncing database\"},\"startedAt\":5000}", recorder.lastEvent);
}

test "sends nothing for a task that carries no job tag" {
    const console_log = logging.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder: EventRecorder = .{
        .calls = 0,
        .lastEvent = "",
    };
    var generators: Generators = .{
        .uuidGenerator = .{},
        .timestampProvider = .{},
    };
    const context = makeContext(&recorder, &generators);

    try sendJobProgress(arena.allocator(), std.testing.io, console_log, context, null, 5000, "12 imported");

    try std.testing.expectEqual(@as(usize, 0), recorder.calls);
}
