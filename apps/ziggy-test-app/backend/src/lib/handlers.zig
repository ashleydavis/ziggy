//
// Everything app.zig registers with Ziggy's core for the test app: its messages and their handlers, its task types, the media
// server, the desktop menu and the functions it runs, the task observers, the error describer and the query of the frontend's address.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");

const HandlerServices = ziggy.core.HandlerServices;
const TaskServices = ziggy.task_runner.TaskServices;
const TaskContext = ziggy.task_runner.TaskContext;
const Timers = ziggy.timers.Timers;
const ILogOptions = ziggy.log.ILogOptions;
const json = ziggy.json;

//
// The handlers of the test app's own messages, each registered by its message name in app.zig, with the payload its data is
// parsed into and the result it returns.
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
// takes the message unparsed, the one handler of the test app that does, so the smoke tests drive that form of handler end to end. It
// logs a line on the main thread, which the smoke tests find in the log files.
//
pub fn pingHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, message: ziggy.core.Message) !ziggy.core.MessageResult {
    _ = timers;
    _ = io;
    services.log.info("ping received");
    const response: PingResponse = .{
        .zigVersion = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .echo = message.data,
    };
    return .{
        .response = try ziggy.json.stringify(allocator, response),
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
pub fn payloadStatsHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: PayloadStatsRequest) !PayloadStatsResponse {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    return .{
        .length = payload.text.len,
        .crc32 = std.hash.Crc32.hash(payload.text),
        .text = payload.text[0..@min(payload.text.len, 64)],
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
pub fn fileRoundtripHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: FileRoundtripRequest) !FileRoundtripResponse {
    _ = timers;
    const data_dir = services.dataDir();
    const path = try std.fs.path.join(allocator, &.{ data_dir, "ziggy-test-app-roundtrip.txt" });
    var directory = try std.Io.Dir.cwd().openDir(io, data_dir, .{});
    directory.close(io);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = payload.text,
    });
    return .{
        .path = path,
        .text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)),
    };
}

//
// The data of fail, which has none.
//
pub const FailRequest = struct {};

//
// Always fails, so the frontend can check that an error reply reaches it.
//
pub fn failHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: FailRequest) !void {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = payload;
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
pub fn refuseHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: NoRequest) !void {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = payload;
    return error.Refused;
}

//
// The test app's error describer: a sentence for the error the refuse message returns, and nothing for any other, which is then replied
// to by name.
//
pub fn describeError(err: anyerror) ?[]const u8 {
    if (err == error.Refused) {
        return "The test app refused, as the request told it to.";
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
pub fn queueFromAppHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: SourceRequest) ![]const u8 {
    _ = timers;
    const task_id = try std.fmt.allocPrint(allocator, "from-app-{s}", .{payload.source});
    try services.addTask(io, allocator, task_id, "hello-short", payload.source, "null", .background);
    try services.sendEvent(io, allocator, try json.stringify(allocator, .{
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
pub fn cancelFromAppHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: SourceRequest) !CancelFromAppResponse {
    _ = timers;
    services.cancelTasks(io, allocator, payload.source);
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
fn sendJobProgress(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, job: ?JobTag, started_at: i64, progress_message: []const u8) !void {
    const tag = job orelse {
        return;
    };
    try services.sendEvent(io, allocator, .{
        .type = "job-progress",
        .job = tag,
        .startedAt = started_at,
        .progressMessage = progress_message,
    });
}

//
// Sends an output event, whose text the frontend shows in its output area.
//
fn sendOutput(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, text: []const u8) !void {
    try services.sendEvent(io, allocator, .{
        .type = "output",
        .text = text,
    });
}

fn nowMilliseconds(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

//
// Does a small amount of work: a log line, an output event, a job-progress event, then done.
//
pub fn helloShortHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) ![]const u8 {
    _ = timers;
    _ = context;
    services.log.info("the short task is running");
    const started_at = nowMilliseconds(io);
    try sendOutput(services, io, allocator, "hello from a short task");
    try sendJobProgress(services, io, allocator, readJobTag(payload), started_at, "short task working");
    return "short task done";
}

//
// What hello-long gives as its result.
//
pub const HelloLongResult = struct {
    // How many steps it took.
    steps: i64,
    // How many children it ran.
    children: usize,
};

//
// Loops for "durationMs" in steps of "stepMs", checking for cancellation at every step and sending an output event
// and a job-progress event at every step. While it runs it queues "children" hello-child tasks, no more than the
// child limit at a time, then waits for them all and reports each one's completion in its own output.
//
pub fn helloLongHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !HelloLongResult {
    _ = context;
    const duration_ms = json.getInteger(payload, "durationMs") orelse 1000;
    const step_ms = json.getInteger(payload, "stepMs") orelse 50;
    const children = json.getInteger(payload, "children") orelse 0;
    const job = readJobTag(payload);
    const started_at = nowMilliseconds(io);
    var child_ids: std.ArrayList([]const u8) = .empty;
    var elapsed: i64 = 0;
    var step: i64 = 0;
    while (elapsed < duration_ms) {
        try services.checkCancelled(io, allocator);
        step += 1;
        const line = try std.fmt.allocPrint(allocator, "long task step {d}", .{step});
        try sendOutput(services, io, allocator, line);
        try sendJobProgress(services, io, allocator, job, started_at, line);
        if (@as(i64, @intCast(child_ids.items.len)) < children) {
            const child_id = try services.queueChild(io, allocator, timers, "hello-child", .{
                .index = child_ids.items.len,
                .job = job,
            }, null);
            try child_ids.append(allocator, child_id);
        }
        try io.sleep(.fromMilliseconds(step_ms), .awake);
        elapsed += step_ms;
    }
    // A task whose input sets more children than it had steps to start them in starts the rest now.
    while (@as(i64, @intCast(child_ids.items.len)) < children) {
        const child_id = try services.queueChild(io, allocator, timers, "hello-child", .{
            .index = child_ids.items.len,
            .job = job,
        }, null);
        try child_ids.append(allocator, child_id);
    }
    for (child_ids.items) |child_id| {
        const completion = try services.awaitTask(io, allocator, timers, child_id);
        const line = try std.fmt.allocPrint(allocator, "child {s} {s}", .{ child_id, @tagName(completion.status) });
        try sendOutput(services, io, allocator, line);
    }
    try services.checkCancelled(io, allocator);
    try sendJobProgress(services, io, allocator, job, started_at, "long task finished");
    return .{
        .steps = step,
        .children = child_ids.items.len,
    };
}

//
// What hello-child gives as its result.
//
pub const HelloChildResult = struct {
    // The child's index among its parent's children.
    index: i64,
};

//
// A child of hello-long: an output event, a job-progress event under the parent's job id, a short wait, then done.
//
pub fn helloChildHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !HelloChildResult {
    _ = timers;
    _ = context;
    const started_at = nowMilliseconds(io);
    const index = json.getInteger(payload, "index") orelse 0;
    const line = try std.fmt.allocPrint(allocator, "child {d} running", .{index});
    try sendOutput(services, io, allocator, line);
    try sendJobProgress(services, io, allocator, readJobTag(payload), started_at, line);
    var waited: i64 = 0;
    while (waited < 100) : (waited += 10) {
        try services.checkCancelled(io, allocator);
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return .{
        .index = index,
    };
}

//
// Always fails, so the failure path is exercised. It logs an error line first, which the smoke tests find in the error log file.
//
pub fn helloFailHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !void {
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = payload;
    services.log.@"error"("the failing task is failing");
    return error.HelloFailure;
}

//
// Has the native app read the operating system's version through its os-version call, by a request to the main thread,
// and returns it.
//
pub fn osVersionHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !json.Raw {
    _ = context;
    _ = payload;
    const text = try services.osVersion(io, allocator, timers);
    try sendOutput(services, io, allocator, "requested the operating system's version");
    return .{
        .text = text,
    };
}

//
// What background-count gives as its result.
//
pub const BackgroundCountResult = struct {
    // How many steps it counted.
    steps: i64,
};

//
// Counts in a file in the app's data directory, one step every 100 milliseconds for "durationMs", so something outside the app can
// see whether the task is still running while the app's window is closed or the app is in the background. The file's name is the
// "file" field of the data, and it holds the number of steps so far. The test app registers it twice, as a keep-alive task type and as
// a normal one.
//
pub fn backgroundCountHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !BackgroundCountResult {
    _ = timers;
    const duration_ms = json.getInteger(payload, "durationMs") orelse 20000;
    const file_name = json.getString(payload, "file") orelse {
        return error.MissingFile;
    };
    const path = try std.fs.path.join(allocator, &.{ context.data_dir, file_name });
    var elapsed: i64 = 0;
    var step: i64 = 0;
    while (elapsed < duration_ms) {
        try services.checkCancelled(io, allocator);
        step += 1;
        const text = try std.fmt.allocPrint(allocator, "{d}\n", .{step});
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = text,
        });
        try io.sleep(.fromMilliseconds(100), .awake);
        elapsed += 100;
    }
    return .{
        .steps = step,
    };
}

//
// Task types that work through their task context and services: one replies with what the context holds about the task, and one runs
// children through the services one after another and stops when the task is cancelled.
//

//
// What describe-self gives as its result.
//
pub const DescribeSelfResult = struct {
    // The task's id.
    taskId: []const u8,
    // The task's type.
    taskType: []const u8,
    // The source the task was queued under.
    source: []const u8,
    // The limit on child tasks in flight.
    maxConcurrentChildTasks: u32,
};

//
// Replies with what a task knows about itself from its context: its id, type and source, and the child task limit.
//
pub fn describeSelfHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !DescribeSelfResult {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = payload;
    return .{
        .taskId = context.task_id,
        .taskType = context.task_type,
        .source = context.source,
        .maxConcurrentChildTasks = context.max_concurrent_child_tasks,
    };
}

//
// What run-in-turn gives as its result.
//
pub const RunInTurnResult = struct {
    // How many children ran.
    ran: usize,
    // How each ended.
    statuses: []const []const u8,
};

//
// Runs "children" hello-child tasks one after another, each freed as soon as it ends, and stops starting them once the task is cancelled,
// reporting in an output event how many it ran. Replies with how many ran and how each ended.
//
pub fn runInTurnHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !RunInTurnResult {
    _ = context;
    const children = json.getInteger(payload, "children") orelse 0;
    var statuses: std.ArrayList([]const u8) = .empty;
    var index: i64 = 0;
    while (index < children and !services.isCancelled(io, allocator)) : (index += 1) {
        // A cancel that lands while the child is being queued ends the call with error.Cancelled instead of a cancelled completion.
        const completion = services.runChild(io, allocator, timers, allocator, "hello-child", .{
            .index = index,
        }, null) catch |err| switch (err) {
            error.Cancelled => break,
            else => return err,
        };
        try statuses.append(allocator, @tagName(completion.status));
    }
    if (services.isCancelled(io, allocator)) {
        try services.sendEvent(io, allocator, .{
            .type = "output",
            .text = try std.fmt.allocPrint(allocator, "run-in-turn stopped after {d} children", .{statuses.items.len}),
        });
        return error.Cancelled;
    }
    return .{
        .ran = statuses.items.len,
        .statuses = statuses.items,
    };
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
// The task: listens, tells the frontend the port and serves connections until the task is cancelled. The connections are accepted
// on a thread of its own (acceptConnections), which owns the listening socket, while the task waits for its cancel. On the cancel
// the task sends that thread "stop" and makes one connection to the port, which wakes it from accept to read it. A connection is
// served on a thread of its own that owns everything it uses, because a browser opens connections it never sends a request on and
// a thread waiting on one cannot be woken. Such a thread ends when the browser closes the connection, and the task does not wait
// for it.
//
pub fn mediaServerHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !void {
    _ = context;
    _ = payload;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const listener = try address.listen(io, .{});
    const port = listener.socket.address.getPort();
    var accept_queue = ziggy.message_queue.MessageQueue.init();
    defer accept_queue.deinit();
    const accepting = std.Thread.spawn(.{}, acceptConnections, .{ listener, &accept_queue }) catch |err| {
        var unused = listener;
        unused.deinit(io);
        return err;
    };
    defer {
        accept_queue.post(io, 0, "stop") catch @panic("out of memory stopping the media server");
        const wake_address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
        if (wake_address.connect(io, .{ .mode = .stream })) |stream| {
            stream.close(io);
        }
        else |_| {}
        accepting.join();
    }
    try services.sendEvent(io, allocator, .{
        .type = "media-server",
        .port = port,
    });
    services.waitUntilCancelled(io, allocator, timers);
    return error.Cancelled;
}

//
// Accepts connections on the listening socket it is given, which it owns and closes, and serves each on a thread of its own, until
// it is sent "stop" on its queue. It blocks in accept and reads its queue after each connection, so the task wakes it with a
// connection of its own after sending "stop".
//
fn acceptConnections(given: std.Io.net.Server, queue: *ziggy.message_queue.MessageQueue) void {
    var listener = given;
    var thread_allocator: ziggy.utils.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();
    defer listener.deinit(io);
    while (true) {
        const stream = listener.accept(io) catch |err| {
            std.debug.print("media server: accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        if (queue.tryTake(io, allocator)) |message| {
            allocator.free(message.text);
            stream.close(io);
            return;
        }
        const thread = std.Thread.spawn(.{}, serveConnection, .{stream}) catch |err| {
            std.debug.print("media server: could not serve a connection: {s}\n", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
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
// The test app's file and folder pickers. The pick-folder, pick-files and pick-file messages each have their response from the task of
// its name: a cancelled dialog is a response of null. Each runs as a task, because a dialog waits for the user and must not hold up the
// thread that handles frontend messages.
//

//
// Shows a dialog and returns the first path chosen as a JSON string, or null when the user cancelled.
//
fn firstPath(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, kind: ziggy.types.PickKind, title: ?[]const u8, initial_name: ?[]const u8) !json.Raw {
    const picked = try services.pickPaths(io, allocator, timers, kind, title, initial_name);
    const paths = try std.json.parseFromSliceLeaky(std.json.Value, allocator, picked, .{});
    if (paths != .array or paths.array.items.len == 0) {
        return .{
            .text = "null",
        };
    }
    return .{
        .text = try json.stringify(allocator, paths.array.items[0]),
    };
}

//
// pick-folder: data is an options object that may name a "title", or null. The reply is the
// folder's path, or null.
//
pub fn pickFolderHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !json.Raw {
    _ = context;
    const title = json.getString(payload, "title") orelse "Select Folder";
    return try firstPath(services, io, allocator, timers, .folder, title, null);
}

//
// pick-files: data is the dialog's title, a string. The reply is the array of the paths chosen, or null.
//
pub fn pickFilesHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !json.Raw {
    _ = context;
    const title: []const u8 = if (payload == .string) payload.string else "Select Files";
    const picked = try services.pickPaths(io, allocator, timers, .open_files, title, null);
    const paths = try std.json.parseFromSliceLeaky(std.json.Value, allocator, picked, .{});
    if (paths != .array or paths.array.items.len == 0) {
        return .{
            .text = "null",
        };
    }
    return .{
        .text = picked,
    };
}

//
// pick-file: a save dialog, where data is the suggested file name, a string. The reply is the path chosen to
// save to, or null.
//
pub fn pickFileHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !json.Raw {
    _ = context;
    const initial_name: []const u8 = if (payload == .string) payload.string else "";
    return try firstPath(services, io, allocator, timers, .save_file, "Save As", initial_name);
}

//
// The data of pick-folder.
//
pub const PickFolderRequest = struct {
    // The dialog's title, or null for the default.
    title: ?[]const u8 = null,
};

//
// pick-folder: the response is the result of the pick-folder task, which is given the payload: the folder's path, or null.
//
pub fn pickFolderMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: PickFolderRequest) !ziggy.core.Response(?[]const u8) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "pick-folder",
            .data = try json.stringify(allocator, payload),
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
// pick-files: the response is the result of the pick-files task, which is given the title: the paths chosen, or null.
//
pub fn pickFilesMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: PickFilesRequest) !ziggy.core.Response(?[]const []const u8) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "pick-files",
            .data = try json.stringify(allocator, payload.title),
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
// pick-file: the response is the result of the pick-file task, which is given the suggested name: the path chosen, or null.
//
pub fn pickFileMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: PickFileRequest) !ziggy.core.Response(?[]const u8) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "pick-file",
            .data = try json.stringify(allocator, payload.name),
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
fn sendObserved(services: HandlerServices, io: std.Io, allocator: std.mem.Allocator, event_type: []const u8, task_id: []const u8) void {
    const event = json.stringify(allocator, .{
        .type = event_type,
        .taskId = task_id,
    }) catch |err| {
        std.debug.panic("the {s} event could not be made: {s}", .{ event_type, @errorName(err) });
    };
    services.sendEvent(io, allocator, event) catch |err| {
        std.debug.panic("the {s} event could not be sent: {s}", .{ event_type, @errorName(err) });
    };
}

//
// The backend's observer of a task that has ended: tells the frontend with a "task-ended" app event.
//
pub fn onTaskEnd(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, end: ziggy.types.TaskEnd) void {
    _ = timers;
    sendObserved(services, io, allocator, "task-ended", end.task_id);
}

//
// The backend's observer of an event a task sent: tells the frontend with a "task-event-sent" app event.
//
pub fn onTaskEvent(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, sent: ziggy.types.TaskSentEvent) void {
    _ = timers;
    sendObserved(services, io, allocator, "task-event-sent", sent.task_id);
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
pub fn sendZigEvent(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) !void {
    _ = timers;
    try services.sendEvent(io, allocator, "{\"type\":\"menu-zig-event\"}");
}

//
// The query of the test app frontend's address.
//

//
// Reports whether the test mode switch is on, which is all the test app's frontend reads from its address.
//
pub fn uiQuery(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, test_mode: bool) anyerror![]const u8 {
    _ = services;
    _ = timers;
    _ = io;
    if (test_mode) {
        return try allocator.dupe(u8, "testMode=1");
    }
    return try allocator.dupe(u8, "");
}

//
// Configures the log once, as early as the app can, from the options on the test app's command line.
//
pub fn onCreate(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) anyerror!void {
    _ = timers;
    _ = io;
    _ = allocator;
    try services.configureLog(logOptions(arguments));
}

//
// The log options on the command line: --verbose, --debug and --tools each turn on their lines. Every other argument is left to
// whatever else reads the command line.
//
pub fn logOptions(arguments: []const []const u8) ILogOptions {
    var options: ILogOptions = .{
        .verbose = false,
        .debug = false,
        .tools = false,
    };
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, "--verbose")) {
            options.verbose = true;
        }
        else if (std.mem.eql(u8, argument, "--debug")) {
            options.debug = true;
        }
        else if (std.mem.eql(u8, argument, "--tools")) {
            options.tools = true;
        }
    }
    return options;
}
