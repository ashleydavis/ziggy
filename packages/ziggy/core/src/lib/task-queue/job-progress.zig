//
// Reporting a task's progress as a user-visible job.
//

const std = @import("std");
const types = @import("types.zig");
const ILog = @import("log").ILog;
const IJobTag = types.IJobTag;
const ITaskContext = types.ITaskContext;

//
// Converts a job tag to the JSON object sent in a task's event (cancelSource is left out when the
// tag has none, as JSON.stringify leaves out an undefined property).
//
fn jobTagToJson(allocator: std.mem.Allocator, job: IJobTag) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "id", .{ .string = job.id });
    try object.put(allocator, "name", .{ .string = job.name });
    if (job.cancelSource) |cancelSource| {
        try object.put(allocator, "cancelSource", .{ .string = cancelSource });
    }
    return .{ .object = object };
}

//
// Reports a job's progress from inside a task handler.
//
// Does nothing when the task carries no job tag, which is how a task without one stays out
// of the interface without its handler having to know that. Automatic import is the case that
// matters: it is the same handler as a manual import, and it runs for as long as the setting is on,
// so a row for it would never go away.
//
// (Zig: the IJobProgressEvent is sent as its JSON object; progressMessage is left out when there is
// none, as JSON.stringify leaves out an undefined property.)
//
pub fn sendJobProgress(allocator: std.mem.Allocator, io: std.Io, log: ILog, context: ITaskContext, job: ?IJobTag, startedAt: i64, progressMessage: ?[]const u8) !void {
    const jobTag = job orelse {
        return;
    };

    var event: std.json.ObjectMap = .empty;
    try event.put(allocator, "type", .{ .string = "job-progress" });
    try event.put(allocator, "job", try jobTagToJson(allocator, jobTag));
    try event.put(allocator, "startedAt", .{ .integer = startedAt });
    if (progressMessage) |text| {
        try event.put(allocator, "progressMessage", .{ .string = text });
    }
    context.sendEvent(io, allocator, log, .{ .object = event });
}
