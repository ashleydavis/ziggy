//
// Everything app.zig registers with Ziggy's core for the test app: its messages and their handlers, its task types, the media
// server, the desktop menu and the functions it runs, the task observers, the error describer and the query of the frontend's address.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");

const TaskContext = ziggy.task_runner.TaskContext;
const Core = ziggy.core.Core;
const json = ziggy.json;

//
// The handlers of the test app's own messages, each registered by its message name in app.zig, with the request its data is
// parsed into and the response it returns.
//

//
// The message response to ping.
//
pub const PingResponse = struct {
    // The version of Zig the backend was built with.
    zigVersion: []const u8,
    // The operating system the backend was built for.
    os: []const u8,
    // The CPU architecture the backend was built for.
    arch: []const u8,
    // The ping's data, unchanged.
    echo: std.json.Value,
};

//
// Replies with the Zig version, the target operating system and CPU architecture, and an echo of the payload, whatever it is. It
// takes the message unparsed, the one handler of the test app that does, so the smoke tests drive that form of handler end to end.
//
pub fn pingHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, message: ziggy.core.Message) !ziggy.core.MessageResult {
    _ = core;
    const response: PingResponse = .{
        .zigVersion = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .echo = message.data,
    };
    return .{
        .response = try ziggy.json.stringify(arena, response),
    };
}

//
// The data of payload-stats.
//
pub const PayloadStatsRequest = struct {
    // The payload to measure.
    text: []const u8,
};

//
// The message response to payload-stats.
//
pub const PayloadStatsResponse = struct {
    // The length of the payload in bytes.
    length: usize,
    // The CRC-32 of the payload.
    crc32: u32,
    // The start of the payload, at most 64 bytes of it.
    text: []const u8,
};

//
// Replies with the length in bytes and the CRC-32 of the "text" field, so the frontend can check a large
// payload arrived whole without the payload coming back.
//
pub fn payloadStatsHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: PayloadStatsRequest) !PayloadStatsResponse {
    _ = core;
    _ = arena;
    return .{
        .length = request.text.len,
        .crc32 = std.hash.Crc32.hash(request.text),
        .text = request.text[0..@min(request.text.len, 64)],
    };
}

//
// The data of file-roundtrip.
//
pub const FileRoundtripRequest = struct {
    // The text to write to the file and read back.
    text: []const u8,
};

//
// The message response to file-roundtrip.
//
pub const FileRoundtripResponse = struct {
    // The path of the file written.
    path: []const u8,
    // What was read back from it.
    text: []const u8,
};

//
// Writes the "text" field to a file in the app's private data directory, reads it back and replies with what it read.
// A data directory that does not exist is an error.
//
pub fn fileRoundtripHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: FileRoundtripRequest) !FileRoundtripResponse {
    const path = try std.fs.path.join(arena, &.{ core.data_dir, "ziggy-test-app-roundtrip.txt" });
    const io = core.io();
    var directory = try std.Io.Dir.cwd().openDir(io, core.data_dir, .{});
    directory.close(io);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = request.text,
    });
    return .{
        .path = path,
        .text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)),
    };
}

//
// The data of fail, which has none.
//
pub const FailRequest = struct {};

//
// Always fails, so the frontend can check that an error reply reaches it.
//
pub fn failHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: FailRequest) !void {
    _ = core;
    _ = arena;
    _ = request;
    return error.ExampleFailure;
}

//
// The test app's error describer, which turns an error into the text of its reply, and the refuse message, whose error it describes.
//

//
// The data of refuse, which has none.
//
pub const NoRequest = struct {};

//
// Always fails with an error the test app's describer has a sentence for, so the frontend can check the sentence is what reaches it.
//
pub fn refuseHandler(core: *Core, arena: std.mem.Allocator, request: NoRequest) !void {
    _ = core;
    _ = arena;
    _ = request;
    return error.Refused;
}

//
// The test app's error describer: a sentence for the error the refuse message returns, and nothing for any other, which is then replied
// to by name.
//
pub fn describeError(err: anyerror) ?[]const u8 {
    if (err == error.Refused) {
        return "The test app refused, as it was asked to.";
    }
    return null;
}

//
// Messages that queue and cancel tasks from the test app's own code rather than from the frontend, telling the frontend with an app
// event when the app queued one.
//

//
// The data of queue-from-app and of cancel-from-app.
//
pub const SourceRequest = struct {
    // The source to queue the task under, or to cancel the tasks of.
    source: []const u8,
};

//
// Queues a hello-short task from the app's own code, under the source given in "source", and tells the frontend with an app event
// of the type "queued-from-app" that it did. The reply is the id of the task.
//
pub fn queueFromAppHandler(core: *Core, arena: std.mem.Allocator, request: SourceRequest) ![]const u8 {
    const task_id = try std.fmt.allocPrint(arena, "from-app-{s}", .{request.source});
    try core.runner.addTask(task_id, "hello-short", request.source, "null", .background, null);
    try core.sendEvent(arena, try json.stringify(arena, .{
        .type = "queued-from-app",
        .queued = task_id,
    }));
    return task_id;
}

//
// The message response to cancel-from-app, an empty object.
//
pub const CancelFromAppResponse = struct {};

//
// Cancels, from the app's own code, the tasks queued under the source given in "source".
//
pub fn cancelFromAppHandler(core: *Core, arena: std.mem.Allocator, request: SourceRequest) !CancelFromAppResponse {
    _ = arena;
    core.runner.cancelSource(request.source);
    return .{};
}

//
// The test app's task types. They are an ordinary part of the test app, kept permanently to show how a task is written.
//

//
// How the test app names a job in its job-progress events, read from the "job" field of a task's data.
//
const JobTag = struct {
    // The job's id. Tasks sharing an id are one job.
    id: []const u8,
    // The job's name.
    name: []const u8,
    // The source whose cancellation cancels the job, when it has one.
    cancelSource: ?[]const u8,
};

//
// Reads the job tag from a task's data, or null when the task is not part of a job.
//
fn readJobTag(data: std.json.Value) ?JobTag {
    if (data != .object) {
        return null;
    }
    const job = data.object.get("job") orelse {
        return null;
    };
    const id = json.getString(job, "id") orelse {
        return null;
    };
    const name = json.getString(job, "name") orelse {
        return null;
    };
    return .{
        .id = id,
        .name = name,
        .cancelSource = json.getString(job, "cancelSource"),
    };
}

//
// Sends a job-progress event, which has the fields of IJobProgressEvent, and does nothing when the task has no job.
//
fn sendJobProgress(context: *TaskContext, job: ?JobTag, started_at: i64, progress_message: []const u8) !void {
    const tag = job orelse {
        return;
    };
    try context.sendEvent(.{
        .type = "job-progress",
        .job = tag,
        .startedAt = started_at,
        .progressMessage = progress_message,
    });
}

//
// Sends an output event, whose text the frontend shows in its output area.
//
fn sendOutput(context: *TaskContext, text: []const u8) !void {
    try context.sendEvent(.{
        .type = "output",
        .text = text,
    });
}

fn nowMilliseconds(context: *TaskContext) i64 {
    return std.Io.Clock.real.now(context.io()).toMilliseconds();
}

//
// Does a small amount of work: an output event, a job-progress event, then done.
//
pub fn helloShortHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const started_at = nowMilliseconds(context);
    try sendOutput(context, "hello from a short task");
    try sendJobProgress(context, readJobTag(data), started_at, "short task working");
    return try context.arena.dupe(u8, "\"short task done\"");
}

//
// Loops for "durationMs" in steps of "stepMs", checking for cancellation at every step and sending an output event
// and a job-progress event at every step. While it runs it queues "children" hello-child tasks, no more than the
// child limit at a time, then waits for them all and reports each one's completion in its own output.
//
pub fn helloLongHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const duration_ms = json.getInteger(data, "durationMs") orelse 1000;
    const step_ms = json.getInteger(data, "stepMs") orelse 50;
    const children = json.getInteger(data, "children") orelse 0;
    const job = readJobTag(data);
    const started_at = nowMilliseconds(context);
    var child_ids: std.ArrayList([]const u8) = .empty;
    var elapsed: i64 = 0;
    var step: i64 = 0;
    while (elapsed < duration_ms) {
        try context.checkCancelled();
        step += 1;
        const line = try std.fmt.allocPrint(context.arena, "long task step {d}", .{step});
        try sendOutput(context, line);
        try sendJobProgress(context, job, started_at, line);
        if (@as(i64, @intCast(child_ids.items.len)) < children) {
            const child_id = try context.queueChild("hello-child", .{
                .index = child_ids.items.len,
                .job = job,
            }, null);
            try child_ids.append(context.arena, child_id);
        }
        try context.io().sleep(.fromMilliseconds(step_ms), .awake);
        elapsed += step_ms;
    }
    // A task whose input sets more children than it had steps to start them in starts the rest now.
    while (@as(i64, @intCast(child_ids.items.len)) < children) {
        const child_id = try context.queueChild("hello-child", .{
            .index = child_ids.items.len,
            .job = job,
        }, null);
        try child_ids.append(context.arena, child_id);
    }
    for (child_ids.items) |child_id| {
        const completion = try context.awaitTask(child_id);
        const line = try std.fmt.allocPrint(context.arena, "child {s} {s}", .{ child_id, @tagName(completion.status) });
        try sendOutput(context, line);
    }
    try context.checkCancelled();
    try sendJobProgress(context, job, started_at, "long task finished");
    return try json.stringify(context.arena, .{
        .steps = step,
        .children = child_ids.items.len,
    });
}

//
// A child of hello-long: an output event, a job-progress event under the parent's job id, a short wait, then done.
//
pub fn helloChildHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const started_at = nowMilliseconds(context);
    const index = json.getInteger(data, "index") orelse 0;
    const line = try std.fmt.allocPrint(context.arena, "child {d} running", .{index});
    try sendOutput(context, line);
    try sendJobProgress(context, readJobTag(data), started_at, line);
    var waited: i64 = 0;
    while (waited < 100) : (waited += 10) {
        try context.checkCancelled();
        try context.io().sleep(.fromMilliseconds(10), .awake);
    }
    return try json.stringify(context.arena, .{
        .index = index,
    });
}

//
// Always fails, so the failure path is exercised.
//
pub fn helloFailHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    _ = data;
    return error.HelloFailure;
}

//
// Calls the native app's os_version native host callback for the operating system's version and returns it.
//
pub fn osVersionHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const os_version = context.config().os_version orelse {
        return error.HostCallbackMissing;
    };
    const buffer = try context.arena.alloc(u8, 1024);
    const length = os_version(context.config().user_data, buffer.ptr, buffer.len);
    if (length < 0) {
        return error.HostCallbackFailed;
    }
    const text = buffer[0..@intCast(length)];
    try sendOutput(context, "asked the operating system for its version");
    return text;
}

//
// Counts in a file in the app's data directory, one step every 100 milliseconds for "durationMs", so something outside the app can
// see whether the task is still running while the app's window is closed or the app is in the background. The file's name is the
// "file" field of the data, and it holds the number of steps so far. The test app registers it twice, as a keep-alive task type and as
// a normal one.
//
pub fn backgroundCountHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const duration_ms = json.getInteger(data, "durationMs") orelse 20000;
    const file_name = json.getString(data, "file") orelse {
        return error.MissingFile;
    };
    const path = try std.fs.path.join(context.arena, &.{ std.mem.span(context.config().data_dir), file_name });
    var elapsed: i64 = 0;
    var step: i64 = 0;
    while (elapsed < duration_ms) {
        try context.checkCancelled();
        step += 1;
        const text = try std.fmt.allocPrint(context.arena, "{d}\n", .{step});
        try std.Io.Dir.cwd().writeFile(context.io(), .{
            .sub_path = path,
            .data = text,
        });
        try context.io().sleep(.fromMilliseconds(100), .awake);
        elapsed += 100;
    }
    return try json.stringify(context.arena, .{
        .steps = step,
    });
}

//
// Task types that work through their task context: one replies with what the context knows about the task, and one runs children
// through it one after another and stops when the task is cancelled.
//

//
// Replies with what a task knows about itself from its context: its id, type and source, and the child task limit.
//
pub fn describeSelfHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    return try json.stringify(context.arena, .{
        .taskId = context.taskId(),
        .taskType = context.taskType(),
        .source = context.source(),
        .maxConcurrentChildTasks = context.maxConcurrentChildTasks(),
    });
}

//
// Runs "children" hello-child tasks one after another, each freed as soon as it ends, and stops starting them once the task is cancelled,
// reporting in an output event how many it ran. Replies with how many ran and how each ended.
//
pub fn runInTurnHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const children = json.getInteger(data, "children") orelse 0;
    var statuses: std.ArrayList([]const u8) = .empty;
    var index: i64 = 0;
    while (index < children and !context.isCancelled()) : (index += 1) {
        // A cancel that lands while the child is being queued ends the call with error.Cancelled instead of a cancelled completion.
        const completion = context.runChild(context.arena, "hello-child", .{
            .index = index,
        }, null) catch |err| switch (err) {
            error.Cancelled => break,
            else => return err,
        };
        try statuses.append(context.arena, @tagName(completion.status));
    }
    if (context.isCancelled()) {
        try context.sendEvent(.{
            .type = "output",
            .text = try std.fmt.allocPrint(context.arena, "run-in-turn stopped after {d} children", .{statuses.items.len}),
        });
        return error.Cancelled;
    }
    return try json.stringify(context.arena, .{
        .ran = statuses.items.len,
        .statuses = statuses.items,
    });
}

//
// A loopback HTTP server that serves the test app's image and video to the frontend. It is the test app's own code and not
// part of Ziggy: an app that needs to show media from outside the frontend's origin starts one like it, and the web view
// fetches the media from it as it would from any web server. It listens on 127.0.0.1 only, on a port the operating system
// chooses.
//
// It runs as a task so that the task's stack owns its state and cancelling the task stops it. The task tells the frontend
// its port with a "media-server" event.
//

//
// One file the server serves, embedded in the test app's backend.
//
const Asset = struct {
    // The request path it is served under.
    path: []const u8,
    // Its Content-Type.
    content_type: []const u8,
    // Its bytes.
    bytes: []const u8,
};

const assets = [_]Asset{
    .{
        .path = "/example.png",
        .content_type = "image/png",
        .bytes = @embedFile("../media/example.png"),
    },
    .{
        .path = "/example.mp4",
        .content_type = "video/mp4",
        .bytes = @embedFile("../media/example.mp4"),
    },
};

//
// A range of bytes of a file, both ends included, as a Range header gives it.
//
pub const ByteRange = struct {
    // The first byte.
    start: usize,
    // The last byte.
    end: usize,
};

//
// Reads the value of a Range header against a file of the given size. Returns null when the header does not name a byte range,
// which means the whole file, and error.Unsatisfiable when the range lies outside the file.
//
pub fn parseRange(header: []const u8, size: usize) error{Unsatisfiable}!?ByteRange {
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, header, prefix)) {
        return null;
    }
    const spec = header[prefix.len..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse {
        return null;
    };
    const first_text = spec[0..dash];
    const last_text = spec[dash + 1 ..];
    if (size == 0) {
        return error.Unsatisfiable;
    }
    if (first_text.len == 0) {
        // "bytes=-N" is the last N bytes.
        const suffix = std.fmt.parseInt(usize, last_text, 10) catch {
            return null;
        };
        if (suffix == 0) {
            return error.Unsatisfiable;
        }
        return .{
            .start = size - @min(suffix, size),
            .end = size - 1,
        };
    }
    const first = std.fmt.parseInt(usize, first_text, 10) catch {
        return null;
    };
    if (first >= size) {
        return error.Unsatisfiable;
    }
    const last = if (last_text.len == 0) size - 1 else std.fmt.parseInt(usize, last_text, 10) catch {
        return null;
    };
    if (last < first) {
        return null;
    }
    return .{
        .start = first,
        .end = @min(last, size - 1),
    };
}

//
// Finds the file served under a request path, ignoring any query, or null when there is none.
//
pub fn findAsset(request_path: []const u8) ?*const Asset {
    const path = request_path[0 .. std.mem.indexOfScalar(u8, request_path, '?') orelse request_path.len];
    for (&assets) |*asset| {
        if (std.mem.eql(u8, asset.path, path)) {
            return asset;
        }
    }
    return null;
}

//
// The task: listens, tells the frontend the port and serves connections until the task is cancelled. A connection is served
// on a thread of its own that owns everything it uses, because a browser opens connections it never sends a request on and a
// thread waiting on one cannot be woken. Such a thread ends when the browser closes the connection, and the task does not wait
// for it.
//
pub fn mediaServerHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const io = context.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    var stopping: std.atomic.Value(bool) = .init(false);
    const watcher = try std.Thread.spawn(.{}, watchForCancel, .{ context, &stopping, port });
    try context.sendEvent(.{
        .type = "media-server",
        .port = port,
    });
    while (true) {
        const stream = listener.accept(io) catch |err| {
            if (stopping.load(.acquire)) {
                break;
            }
            std.debug.print("media server: accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        if (stopping.load(.acquire)) {
            stream.close(io);
            break;
        }
        const thread = std.Thread.spawn(.{}, serveConnection, .{stream}) catch |err| {
            std.debug.print("media server: could not serve a connection: {s}\n", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
    stopping.store(true, .release);
    watcher.join();
    return error.Cancelled;
}

//
// Wakes the accepting loop when the task is cancelled. Accepting blocks, so a connection made here makes it look at the flag.
//
fn watchForCancel(context: *TaskContext, stopping: *std.atomic.Value(bool), port: u16) void {
    while (!stopping.load(.acquire)) {
        context.checkCancelled() catch {
            stopping.store(true, .release);
            const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
            if (address.connect(context.io(), .{ .mode = .stream })) |stream| {
                stream.close(context.io());
            }
            else |err| {
                // Without the connection the accepting loop never wakes, and the task never ends.
                std.debug.panic("media server: could not wake the accepting loop to stop it: {s}", .{@errorName(err)});
            }
            return;
        };
        context.io().sleep(.fromMilliseconds(50), .awake) catch |err| {
            std.debug.panic("media server: the watch for a cancel could not wait: {s}", .{@errorName(err)});
        };
    }
}

//
// Reads one request from the connection, sends the response and closes the connection.
//
fn serveConnection(stream: std.Io.net.Stream) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    defer stream.close(io);
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    answerRequest(&reader.interface, &writer.interface) catch |err| {
        if (err != error.ReadFailed and err != error.EndOfStream) {
            std.debug.print("media server: a request failed: {s}\n", .{@errorName(err)});
        }
    };
}

//
// Reads the request line and headers from the reader and writes the response to the writer.
//
fn answerRequest(reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    const request_line = std.mem.trimEnd(u8, try reader.takeDelimiterInclusive('\n'), "\r\n");
    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = parts.next() orelse {
        return error.BadRequest;
    };
    const request_path = parts.next() orelse {
        return error.BadRequest;
    };
    var range_header: ?[]const u8 = null;
    var range_copy: [128]u8 = undefined;
    while (true) {
        const line = std.mem.trimEnd(u8, try reader.takeDelimiterInclusive('\n'), "\r\n");
        if (line.len == 0) {
            break;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            continue;
        };
        if (std.ascii.eqlIgnoreCase(line[0..colon], "range")) {
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (value.len <= range_copy.len) {
                @memcpy(range_copy[0..value.len], value);
                range_header = range_copy[0..value.len];
            }
        }
    }
    const cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: range\r\n";
    if (std.mem.eql(u8, method, "OPTIONS")) {
        try writer.print("HTTP/1.1 204 No Content\r\n{s}Content-Length: 0\r\nConnection: close\r\n\r\n", .{cors});
        try writer.flush();
        return;
    }
    const is_head = std.mem.eql(u8, method, "HEAD");
    if (!is_head and !std.mem.eql(u8, method, "GET")) {
        try writer.print("HTTP/1.1 405 Method Not Allowed\r\n{s}Content-Length: 0\r\nConnection: close\r\n\r\n", .{cors});
        try writer.flush();
        return;
    }
    const asset = findAsset(request_path) orelse {
        try writer.print("HTTP/1.1 404 Not Found\r\n{s}Content-Length: 0\r\nConnection: close\r\n\r\n", .{cors});
        try writer.flush();
        return;
    };
    const range = if (range_header) |header| parseRange(header, asset.bytes.len) catch {
        try writer.print("HTTP/1.1 416 Range Not Satisfiable\r\n{s}Content-Range: bytes */{d}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ cors, asset.bytes.len });
        try writer.flush();
        return;
    } else null;
    if (range) |found| {
        const body = asset.bytes[found.start .. found.end + 1];
        try writer.print(
            "HTTP/1.1 206 Partial Content\r\n{s}Content-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ cors, asset.content_type, found.start, found.end, asset.bytes.len, body.len },
        );
        if (!is_head) {
            try writer.writeAll(body);
        }
    }
    else {
        try writer.print(
            "HTTP/1.1 200 OK\r\n{s}Content-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ cors, asset.content_type, asset.bytes.len },
        );
        if (!is_head) {
            try writer.writeAll(asset.bytes);
        }
    }
    try writer.flush();
}

//
// The test app's file and folder pickers. They answer the pick-folder, pick-files and pick-file messages, each handler answering with the task of its name: a
// cancelled dialog is a reply of null. Each runs as a task, because a dialog waits for the user and must not hold up the thread that handles frontend
// messages.
//

//
// Shows a dialog and returns the first path chosen as a JSON string, or null when the user cancelled.
//
fn firstPath(context: *TaskContext, kind: ziggy.types.PickKind, title: ?[]const u8, initial_name: ?[]const u8) !?[]const u8 {
    const answer = try context.pickPaths(kind, title, initial_name);
    const paths = try std.json.parseFromSliceLeaky(std.json.Value, context.arena, answer, .{});
    if (paths != .array or paths.array.items.len == 0) {
        return try context.arena.dupe(u8, "null");
    }
    return try json.stringify(context.arena, paths.array.items[0]);
}

//
// pick-folder: data is an options object that may name a "title", or null. The reply is the
// folder's path, or null.
//
pub fn pickFolderHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const title = json.getString(data, "title") orelse "Select Folder";
    return try firstPath(context, .folder, title, null);
}

//
// pick-files: data is the dialog's title, a string. The reply is the array of the paths chosen, or null.
//
pub fn pickFilesHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const title: []const u8 = if (data == .string) data.string else "Select Files";
    const answer = try context.pickPaths(.open_files, title, null);
    const paths = try std.json.parseFromSliceLeaky(std.json.Value, context.arena, answer, .{});
    if (paths != .array or paths.array.items.len == 0) {
        return try context.arena.dupe(u8, "null");
    }
    return answer;
}

//
// pick-file: a save dialog, where data is the suggested file name, a string. The reply is the path chosen to
// save to, or null.
//
pub fn pickFileHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const initial_name: []const u8 = if (data == .string) data.string else "";
    return try firstPath(context, .save_file, "Save As", initial_name);
}

//
// The data of pick-folder.
//
pub const PickFolderRequest = struct {
    // The dialog's title, or null for the default.
    title: ?[]const u8 = null,
};

//
// pick-folder: answered by the pick-folder task, which is given the request. The response is the folder's path, or null.
//
pub fn pickFolderMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: PickFolderRequest) !ziggy.core.Answer(?[]const u8) {
    _ = core;
    return .{
        .task = .{
            .task_type = "pick-folder",
            .data = try json.stringify(arena, request),
        },
    };
}

//
// The data of pick-files.
//
pub const PickFilesRequest = struct {
    // The dialog's title, or null for the default.
    title: ?[]const u8 = null,
};

//
// pick-files: answered by the pick-files task, which is given the title. The response is the paths chosen, or null.
//
pub fn pickFilesMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: PickFilesRequest) !ziggy.core.Answer(?[]const []const u8) {
    _ = core;
    return .{
        .task = .{
            .task_type = "pick-files",
            .data = try json.stringify(arena, request.title),
        },
    };
}

//
// The data of pick-file.
//
pub const PickFileRequest = struct {
    // The suggested file name, or null for none.
    name: ?[]const u8 = null,
};

//
// pick-file: answered by the pick-file task, which is given the suggested name. The response is the path chosen, or null.
//
pub fn pickFileMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: PickFileRequest) !ziggy.core.Answer(?[]const u8) {
    _ = core;
    return .{
        .task = .{
            .task_type = "pick-file",
            .data = try json.stringify(arena, request.name),
        },
    };
}

//
// The observers the test app gives the backend, called when a task ends or sends an event. Each tells the frontend which task it was
// called for, so the frontend can count what the backend observed.
//

//
// Tells the frontend, with an app event of the type given, which task an observer was called for, so the frontend can count what the
// backend observed. An event that cannot be made is a panic: an observer has no caller to return an error to.
//
fn sendObserved(core: *Core, event_type: []const u8, task_id: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(core.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const event = json.stringify(arena, .{
        .type = event_type,
        .taskId = task_id,
    }) catch |err| {
        std.debug.panic("the {s} event could not be made: {s}", .{ event_type, @errorName(err) });
    };
    core.sendEvent(arena, event) catch |err| {
        std.debug.panic("the {s} event could not be sent: {s}", .{ event_type, @errorName(err) });
    };
}

//
// The backend's observer of a task that has ended: tells the frontend with a "task-ended" app event.
//
pub fn onTaskEnd(core: *Core, end: ziggy.types.TaskEnd) void {
    sendObserved(core, "task-ended", end.task_id);
}

//
// The backend's observer of an event a task sent: tells the frontend with a "task-event-sent" app event.
//
pub fn onTaskEvent(core: *Core, sent: ziggy.types.TaskSentEvent) void {
    sendObserved(core, "task-event-sent", sent.task_id);
}

//
// The test app's desktop menu. The native app draws it with the platform's own menu API on every desktop platform and never on a phone.
//
// Each item names what it runs. A `.standard` item is an action the native app does itself (quit, close-window, reload, the zoom and
// editing actions, full screen and the developer tools). A `.zig` item calls a Zig function of the app's on the thread that handles
// messages. A `.ui` item reaches the frontend as the app event {"type": "menu", "item": "<name>"}; each of those has a `.name`. The
// Example menu's task items and About are the frontend's. Send Event From Zig runs sendZigEvent, below. See "Menus" in the
// architecture document.
//

//
// The menu the test app passes to ziggy.core.App as `.menu`.
//
pub const menu: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .label = "Close Window",
                .accelerator = "CmdOrCtrl+W",
                .run = .{
                    .standard = .@"close-window",
                },
            },
            .{
                .label = "Quit",
                .accelerator = "CmdOrCtrl+Q",
                .run = .{
                    .standard = .quit,
                },
            },
        },
    },
    .{
        .label = "Edit",
        .items = &.{
            .{
                .label = "Undo",
                .accelerator = "CmdOrCtrl+Z",
                .run = .{
                    .standard = .undo,
                },
            },
            .{
                .label = "Redo",
                .accelerator = "CmdOrCtrl+Shift+Z",
                .run = .{
                    .standard = .redo,
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Cut",
                .accelerator = "CmdOrCtrl+X",
                .run = .{
                    .standard = .cut,
                },
            },
            .{
                .label = "Copy",
                .accelerator = "CmdOrCtrl+C",
                .run = .{
                    .standard = .copy,
                },
            },
            .{
                .label = "Paste",
                .accelerator = "CmdOrCtrl+V",
                .run = .{
                    .standard = .paste,
                },
            },
            .{
                .label = "Select All",
                .accelerator = "CmdOrCtrl+A",
                .run = .{
                    .standard = .@"select-all",
                },
            },
        },
    },
    .{
        .label = "View",
        .items = &.{
            .{
                .label = "Reload",
                .accelerator = "CmdOrCtrl+R",
                .run = .{
                    .standard = .reload,
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Zoom In",
                .accelerator = "CmdOrCtrl+Plus",
                .run = .{
                    .standard = .@"zoom-in",
                },
            },
            .{
                .label = "Zoom Out",
                .accelerator = "CmdOrCtrl+Minus",
                .run = .{
                    .standard = .@"zoom-out",
                },
            },
            .{
                .label = "Actual Size",
                .accelerator = "CmdOrCtrl+0",
                .run = .{
                    .standard = .@"zoom-reset",
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Toggle Full Screen",
                .accelerator = "F11",
                .run = .{
                    .standard = .@"toggle-fullscreen",
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Toggle Developer Tools",
                .accelerator = "CmdOrCtrl+Shift+I",
                .run = .{
                    .standard = .@"toggle-devtools",
                },
            },
        },
    },
    .{
        .label = "Example",
        .items = &.{
            .{
                .label = "Start Short Task",
                .name = "start-short",
                .accelerator = "CmdOrCtrl+9",
                .run = .ui,
            },
            .{
                .label = "Start Long Task",
                .name = "start-long",
                .accelerator = "CmdOrCtrl+2",
                .run = .ui,
            },
            .{
                .label = "Start Three Long Tasks",
                .name = "start-many",
                .accelerator = "CmdOrCtrl+3",
                .run = .ui,
            },
            ziggy.menu.separator,
            .{
                .label = "Cancel Long Task",
                .name = "cancel-long",
                .accelerator = "CmdOrCtrl+4",
                .run = .ui,
            },
            ziggy.menu.separator,
            .{
                .label = "Send Event From Zig",
                .name = "zig-event",
                .run = .{
                    .zig = sendZigEvent,
                },
            },
        },
    },
    .{
        .label = "Help",
        .items = &.{
            .{
                .label = "About Ziggy Test App",
                .name = "about",
                .run = .ui,
            },
        },
    },
};

//
// The Zig functions the test app's menu items run (its `.zig` items).
//

//
// Send Event From Zig: sends the frontend the app event {"type": "menu-zig-event"}, which shows that a `.zig` item ran in the core
// and that what it sends reaches the frontend.
//
pub fn sendZigEvent(core: *ziggy.core.Core, arena: std.mem.Allocator) !void {
    try core.sendEvent(arena, "{\"type\":\"menu-zig-event\"}");
}

//
// The query of the test app frontend's address.
//

//
// Reports whether the test mode switch is on, which is all the test app's frontend reads from its address.
//
pub fn uiQuery(core: *ziggy.core.Core, allocator: std.mem.Allocator, test_mode: bool) anyerror![]const u8 {
    _ = core;
    if (test_mode) {
        return try allocator.dupe(u8, "testMode=1");
    }
    return try allocator.dupe(u8, "");
}
