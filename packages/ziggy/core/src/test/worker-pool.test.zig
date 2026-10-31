const std = @import("std");
const ziggy = @import("ziggy");

const MessageQueue = ziggy.message_queue.MessageQueue;
const WorkerPool = ziggy.worker_pool.WorkerPool;
const TaskContext = ziggy.task_runner.TaskContext;
const TaskServices = ziggy.task_runner.TaskServices;
const Timers = ziggy.timers.Timers;
const TimerList = ziggy.timers.TimerList;
const utils = ziggy.utils;
const ziggy_log = ziggy.log;

//
// Returns the task's data as its result, after sending the event {"type":"note"}.
//
fn echoTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !std.json.Value {
    _ = timers;
    _ = context;
    try services.sendEvent(io, allocator, .{ .type = "note" });
    return payload;
}

//
// Waits, looking for a cancel every millisecond, until its task is cancelled.
//
fn waitForCancelTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !void {
    _ = timers;
    _ = context;
    _ = payload;
    while (true) {
        try services.checkCancelled(io, allocator);
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

//
// Queues waitForCancelTask as a child and waits for it, and then fails as cancelled when it has been.
//
fn parentOfWaiterTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) ![]const u8 {
    _ = context;
    _ = payload;
    const child = try services.queueChild(io, allocator, timers, "wait-for-cancel", .{}, null);
    const completion = try services.awaitTask(io, allocator, timers, child);
    try services.checkCancelled(io, allocator);
    return @tagName(completion.status);
}

//
// Queues echoTask as a child, waits for it and returns its result.
//
fn parentOfEchoTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !ziggy.json.Raw {
    _ = context;
    _ = payload;
    const child = try services.queueChild(io, allocator, timers, "echo", .{ .from = "child" }, null);
    const completion = try services.awaitTask(io, allocator, timers, child);
    return .{
        .text = completion.result_json.?,
    };
}

//
// Writes a line to its worker's log and one to its worker's console, which reach the main thread's output.
//
fn logTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !void {
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = payload;
    services.log.info("logged on a worker");
    ziggy_log.console.@"error"("written to a worker's console");
}

//
// Logs an error with its cause on its worker's log.
//
fn logExceptionTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !void {
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = payload;
    services.log.exception("failed on a worker", error.Boom);
}

//
// Logs a verbose line and the output of a tool on its worker's log.
//
fn logDetailTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !void {
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = payload;
    services.log.verbose("verbose on a worker");
    services.log.tool("magick", .{
        .stdout = "tool output on a worker",
        .stderr = null,
    });
}

//
// Reads the operating system's version through the native app.
//
fn osVersionTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !ziggy.json.Raw {
    _ = context;
    _ = payload;
    return .{
        .text = try services.osVersion(io, allocator, timers),
    };
}

//
// Shows a file dialog through the native app.
//
fn pickTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, payload: std.json.Value) !ziggy.json.Raw {
    _ = context;
    _ = payload;
    return .{
        .text = try services.pickPaths(io, allocator, timers, .open_files, null, null),
    };
}

//
// The task types of these tests.
//
const tasks = [_]ziggy.task_runner.TaskHandlerEntry{
    .{ .name = "echo", .handler = ziggy.task_runner.wrapTask("echo", echoTask) },
    .{ .name = "wait-for-cancel", .handler = ziggy.task_runner.wrapTask("wait-for-cancel", waitForCancelTask) },
    .{ .name = "parent-of-waiter", .handler = ziggy.task_runner.wrapTask("parent-of-waiter", parentOfWaiterTask) },
    .{ .name = "parent-of-echo", .handler = ziggy.task_runner.wrapTask("parent-of-echo", parentOfEchoTask) },
    .{ .name = "log", .handler = ziggy.task_runner.wrapTask("log", logTask) },
    .{ .name = "log-exception", .handler = ziggy.task_runner.wrapTask("log-exception", logExceptionTask) },
    .{ .name = "log-detail", .handler = ziggy.task_runner.wrapTask("log-detail", logDetailTask) },
    .{ .name = "os-version", .handler = ziggy.task_runner.wrapTask("os-version", osVersionTask) },
    .{ .name = "pick", .handler = ziggy.task_runner.wrapTask("pick", pickTask) },
};

//
// A pool run by the test's thread, as its main thread, with what it tells the frontend and its observer recorded.
//
const Fixture = struct {
    // The queue the workers send their messages to.
    queue: MessageQueue,
    // The pool.
    pool: WorkerPool,
    // Every message the pool sent the frontend, and every line the observer was given, in order.
    seen: std.ArrayList([]u8),
    // The log the test gives the pool as the main thread's, where the workers' lines are written.
    log: ziggy_log.log.ILog,

    fn init(self: *Fixture, workers: u32, native: bool, log: ziggy_log.log.ILog) void {
        self.log = log;
        self.queue = MessageQueue.init();
        self.seen = .empty;
        self.pool = WorkerPool.init(&self.queue, .{
            .max_workers = workers,
            .tasks = &tasks,
            .worker_options = .{
                .workerId = 0,
                .sessionId = "pool-test",
                .maxConcurrentChildTasks = 4,
                .hasOsVersion = true,
            },
            .sink = .{
                .user_data = self,
                .emit = emit,
            },
            .observe = true,
            .native_request = if (native) .{
                .user_data = self,
                .handle = respondNative,
            } else null,
        });
    }

    fn deinit(self: *Fixture, timers: Timers) void {
        self.pool.shutdown(std.testing.io, std.testing.allocator, timers, self.log, null);
        self.queue.deinit();
        for (self.seen.items) |text| {
            std.testing.allocator.free(text);
        }
        self.seen.deinit(std.testing.allocator);
    }

    fn record(self: *Fixture, text: []const u8) void {
        self.seen.append(std.testing.allocator, std.testing.allocator.dupe(u8, text) catch @panic("out of memory")) catch @panic("out of memory");
    }

    fn emit(user_data: ?*anyopaque, io: std.Io, message: []const u8) void {
        _ = io;
        const self: *Fixture = @ptrCast(@alignCast(user_data.?));
        self.record(message);
    }

    //
    // Hands a message from the queue to the pool, as the main thread does, then records the notices it kept. Returns false when no
    // worker of the pool sent it.
    //
    fn receive(self: *Fixture, timers: Timers, message: ziggy.message_queue.Message) bool {
        const received = self.pool.receive(std.testing.io, std.testing.allocator, timers, self.log, message);
        self.takeNotices();
        return received;
    }

    //
    // Records the notices the pool kept of tasks that ended and events tasks sent, as the main thread hands them to the app.
    //
    fn takeNotices(self: *Fixture) void {
        while (self.pool.takeNotice()) |notice| {
            defer notice.deinit(std.testing.allocator);
            switch (notice) {
                .task_end => |end| self.observeEnd(end),
                .task_event => |sent| self.observeEvent(sent),
            }
        }
    }

    fn observeEnd(self: *Fixture, end: ziggy.types.TaskEnd) void {
        var buffer: [512]u8 = undefined;
        self.record(std.fmt.bufPrint(&buffer, "end|{s}|{s}|{s}|started={}", .{ end.task_id, end.task_type, @tagName(end.status), end.started }) catch unreachable);
    }

    fn observeEvent(self: *Fixture, sent: ziggy.types.TaskSentEvent) void {
        var buffer: [512]u8 = undefined;
        self.record(std.fmt.bufPrint(&buffer, "event|{s}|{s}", .{ sent.task_id, sent.event_json }) catch unreachable);
    }

    //
    // Responds to a native app request as a native app would: the operating system's version, or "[]" for a dialog.
    //
    fn respondNative(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, worker: *ziggy.worker.Worker, request_json: []const u8) void {
        const self: *Fixture = @ptrCast(@alignCast(user_data.?));
        self.record(request_json);
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const request = ziggy.worker_messages.decode(ziggy.worker_messages.INativeAppRequestMessage, arena_state.allocator(), request_json) catch @panic("bad request");
        const result = if (std.mem.eql(u8, request.function, "os-version")) "\"Test OS 2\"" else "[]";
        const response = ziggy.json.stringify(arena_state.allocator(), .{
            .type = "native-app-response",
            .requestId = request.requestId,
            .result = result,
        }) catch @panic("out of memory");
        worker.postMessage(io, response) catch @panic("out of memory");
    }

    //
    // Reads the workers' messages until something the pool sent or the observer was given contains the text. A pool that never gets
    // there fails the test after ten seconds with no message, rather than leaving it running.
    //
    fn waitFor(self: *Fixture, timers: Timers, text: []const u8) !void {
        while (self.indexOf(text) == null) {
            const message = self.queue.take(std.testing.io, std.testing.allocator, .{
                .duration = .{
                    .raw = .fromMilliseconds(10_000),
                    .clock = .awake,
                },
            }) orelse {
                return error.TimedOut;
            };
            defer std.testing.allocator.free(message.text);
            if (!self.receive(timers, message)) {
                @panic("a message came from no worker of the pool");
            }
        }
    }

    fn indexOf(self: *Fixture, text: []const u8) ?usize {
        for (self.seen.items, 0..) |seen, index| {
            if (std.mem.indexOf(u8, seen, text) != null) {
                return index;
            }
        }
        return null;
    }
};

test "a task sent to a worker ends, and the frontend and the observer are told how" {
    const console_log = ziggy_log.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(1, false, console_log);
    defer fixture.deinit(timer_list.interface());
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "t1", "echo", "s", "{\"a\":1}", .background, null);
    try fixture.waitFor(timer_list.interface(), "end|t1|echo|succeeded|started=true");
    try std.testing.expect(fixture.indexOf("{\"kind\":\"system\",\"name\":\"task-completed\",\"data\":{\"taskId\":\"t1\",\"result\":{\"taskId\":\"t1\",\"status\":\"succeeded\",\"outputs\":{\"a\":1},\"type\":\"echo\",\"inputs\":{\"a\":1}}}}") != null);
}

test "a task's event reaches the frontend, then the observer" {
    const console_log = ziggy_log.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(1, false, console_log);
    defer fixture.deinit(timer_list.interface());
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "t1", "echo", "s", "null", .background, null);
    try fixture.waitFor(timer_list.interface(), "end|t1|echo|succeeded");
    const frontend = fixture.indexOf("{\"kind\":\"system\",\"name\":\"task-event\",\"data\":{\"taskId\":\"t1\",\"source\":\"s\",\"data\":{\"type\":\"note\"}}}") orelse return error.NotSeen;
    const observer = fixture.indexOf("event|t1|{\"type\":\"note\"}") orelse return error.NotSeen;
    try std.testing.expect(frontend < observer);
}

test "a task that replies to a message ends as that message's reply" {
    const console_log = ziggy_log.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(1, false, console_log);
    defer fixture.deinit(timer_list.interface());
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "r1", "echo", "request", "\"hi\"", .interactive, "7");
    try fixture.waitFor(timer_list.interface(), "end|r1|echo|succeeded");
    try std.testing.expect(fixture.indexOf("{\"id\":7,\"ok\":true,\"data\":\"hi\"}") != null);
    try std.testing.expect(fixture.indexOf("\"name\":\"task-completed\"") == null);
}

test "a worker's log lines and console lines reach the main thread's output" {
    // The test's thread is the pool's main thread, so the workers' log lines are written to this log.
    const memory = try ziggy_log.memory_log.MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_capture = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_capture = std.Io.Writer.fixed(&stderr_buffer);
    // The capture of the main thread's console is where the workers' console lines are written.
    ziggy_log.console.setCapture(&stdout_capture, &stderr_capture);
    defer ziggy_log.console.setCapture(null, null);
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(1, false, memory.log);
    defer fixture.deinit(timer_list.interface());
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "l1", "log", "s", "null", .background, null);
    try fixture.waitFor(timer_list.interface(), "end|l1|log|succeeded");
    try std.testing.expect(std.mem.indexOf(u8, memory.stdout(), "[Worker 1] logged on a worker\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.buffered(), "written to a worker's console") != null);
}

test "with a file log on the main thread, a worker's lines reach the log file tagged with the worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_capture = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_capture = std.Io.Writer.fixed(&stderr_buffer);
    ziggy_log.console.setCapture(&stdout_capture, &stderr_capture);
    defer ziggy_log.console.setCapture(null, null);
    const allocator = std.testing.allocator;
    const logs_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/logs", .{&tmp.sub_path});
    defer allocator.free(logs_dir);
    const logger = try ziggy_log.file_log.FileLog.start(allocator, std.testing.io, .{
        .file_prefix = "pool-test",
        .title = "Pool Test Log",
        .logs_dir = logs_dir,
        .command = null,
        .version = "1.0.0",
        .header_lines = &.{},
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer logger.stop(allocator, std.testing.io);
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(1, false, logger.ilog());
    defer fixture.deinit(timer_list.interface());
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "l1", "log", "s", "null", .background, null);
    try fixture.waitFor(timer_list.interface(), "end|l1|log|succeeded");
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "x1", "log-exception", "s", "null", .background, null);
    try fixture.waitFor(timer_list.interface(), "end|x1|log-exception|succeeded");
    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, logger.getLogFilePath(), allocator, .limited(1024 * 1024));
    defer allocator.free(written);
    const errors_written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, logger.getErrorLogFilePath(), allocator, .limited(1024 * 1024));
    defer allocator.free(errors_written);
    try std.testing.expect(std.mem.indexOf(u8, written, "] [INFO] [Worker 1] logged on a worker\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "] [ERROR] [Worker 1] failed on a worker\nError: Boom\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors_written, "] [ERROR] [Worker 1] failed on a worker\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.buffered(), "[Worker 1] logged on a worker\n") != null);
}

test "a worker started while the main thread's log passes its lines to a file log sends its verbose and tool lines, which reach the file and not the console" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_capture = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_capture = std.Io.Writer.fixed(&stderr_buffer);
    ziggy_log.console.setCapture(&stdout_capture, &stderr_capture);
    defer ziggy_log.console.setCapture(null, null);
    const allocator = std.testing.allocator;
    const logs_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/logs", .{&tmp.sub_path});
    defer allocator.free(logs_dir);
    const logger = try ziggy_log.file_log.FileLog.start(allocator, std.testing.io, .{
        .file_prefix = "pool-test",
        .title = "Pool Test Log",
        .logs_dir = logs_dir,
        .command = null,
        .version = "1.0.0",
        .header_lines = &.{},
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer logger.stop(allocator, std.testing.io);
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    // The main thread's log is the file log, as Ziggy's main thread's is for an app with a name.
    fixture.init(1, false, logger.ilog());
    defer fixture.deinit(timer_list.interface());
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "d1", "log-detail", "s", "null", .background, null);
    try fixture.waitFor(timer_list.interface(), "end|d1|log-detail|succeeded");
    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, logger.getLogFilePath(), allocator, .limited(1024 * 1024));
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "] [VERBOSE] [Worker 1] verbose on a worker\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "] [TOOL] == [Worker 1] magick stdout ==\ntool output on a worker\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.buffered(), "verbose on a worker") == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.buffered(), "tool output on a worker") == null);
}

test "a worker started with no file log on the main thread sends no verbose or tool lines" {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_capture = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_capture = std.Io.Writer.fixed(&stderr_buffer);
    ziggy_log.console.setCapture(&stdout_capture, &stderr_capture);
    defer ziggy_log.console.setCapture(null, null);
    var recording: ErrorRecordingLog = .{};
    defer recording.deinit();
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(1, false, recording.ilog());
    defer fixture.deinit(timer_list.interface());
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "d1", "log-detail", "s", "null", .background, null);
    try fixture.waitFor(timer_list.interface(), "end|d1|log-detail|succeeded");
    try std.testing.expectEqual(@as(usize, 0), recording.others);
}

//
// A log that records each error line it is given, for a test to give the pool as the main thread's log.
//
const ErrorRecordingLog = struct {
    // Each error line, in order.
    errors: std.ArrayList([]u8) = .empty,
    // How many verbose and tool lines it was given.
    others: usize = 0,

    fn ilog(self: *ErrorRecordingLog) ziggy_log.log.ILog {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *ErrorRecordingLog) void {
        for (self.errors.items) |text| {
            std.testing.allocator.free(text);
        }
        self.errors.deinit(std.testing.allocator);
    }

    const vtable: ziggy_log.log.ILog.VTable = .{
        .info = ignore,
        .verbose = countVerbose,
        .@"error" = recordError,
        .exception = recordException,
        .warn = ignore,
        .debug = ignore,
        .tool = countTool,
        .event = ignore,
        .verboseEnabled = verboseEnabled,
        .getLogDetails = getLogDetails,
        .logFilePath = logFilePath,
    };

    fn ignore(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        _ = message;
    }

    fn recordError(ptr: *anyopaque, message: []const u8) void {
        const self: *ErrorRecordingLog = @ptrCast(@alignCast(ptr));
        self.errors.append(std.testing.allocator, std.testing.allocator.dupe(u8, message) catch @panic("out of memory")) catch @panic("out of memory");
    }

    fn recordException(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        _ = err catch {};
        recordError(ptr, message);
    }

    fn countVerbose(ptr: *anyopaque, message: []const u8) void {
        _ = message;
        const self: *ErrorRecordingLog = @ptrCast(@alignCast(ptr));
        self.others += 1;
    }

    fn countTool(ptr: *anyopaque, tool_name: []const u8, data: ziggy_log.log.IToolOutput) void {
        _ = tool_name;
        _ = data;
        const self: *ErrorRecordingLog = @ptrCast(@alignCast(ptr));
        self.others += 1;
    }

    fn verboseEnabled(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }

    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!ziggy_log.log.ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return ziggy_log.log.noLogDetails;
    }

    fn logFilePath(ptr: *anyopaque) ?[]const u8 {
        _ = ptr;
        return null;
    }
};

test "an error a worker logs with its cause reaches the main thread's log as one error line, with the cause under it" {
    var recording: ErrorRecordingLog = .{};
    defer recording.deinit();
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(1, false, recording.ilog());
    defer fixture.deinit(timer_list.interface());
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "x1", "log-exception", "s", "null", .background, null);
    try fixture.waitFor(timer_list.interface(), "end|x1|log-exception|succeeded");
    try std.testing.expectEqual(@as(usize, 1), recording.errors.items.len);
    try std.testing.expect(std.mem.startsWith(u8, recording.errors.items[0], "[Worker 1] failed on a worker\n"));
    try std.testing.expect(std.mem.indexOf(u8, recording.errors.items[0], "Boom") != null);
}

test "a task's request to the native app reaches the main thread's handler, and the task gets its response" {
    const console_log = ziggy_log.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(1, true, console_log);
    defer fixture.deinit(timer_list.interface());
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "o1", "os-version", "s", "null", .background, null);
    try fixture.waitFor(timer_list.interface(), "end|o1|os-version|succeeded");
    try std.testing.expect(fixture.indexOf("\"type\":\"native-app-request\",\"requestId\":1,\"function\":\"os-version\"") != null);
    try std.testing.expect(fixture.indexOf("\"outputs\":\"Test OS 2\"") != null);
}

test "with no handler for the native app's requests, a task's request fails as NativeCallMissing" {
    const console_log = ziggy_log.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(1, false, console_log);
    defer fixture.deinit(timer_list.interface());
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "p1", "pick", "s", "null", .background, null);
    try fixture.waitFor(timer_list.interface(), "end|p1|pick|failed");
    try std.testing.expect(fixture.indexOf("\"errorMessage\":\"NativeCallMissing\"") != null);
}

test "a child a task queues runs, and its end goes back to the worker of the task that queued it" {
    const console_log = ziggy_log.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(2, false, console_log);
    defer fixture.deinit(timer_list.interface());
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "p1", "parent-of-echo", "s", "null", .background, null);
    try fixture.waitFor(timer_list.interface(), "end|p1|parent-of-echo|succeeded");
    try std.testing.expect(fixture.indexOf("end|p1.c0|echo|succeeded") != null);
    try std.testing.expect(fixture.indexOf("\"taskId\":\"p1\",\"status\":\"succeeded\",\"outputs\":{\"from\":\"child\"}") != null);
}

test "cancelling a source ends its waiting tasks as cancelled without starting them, and stops its running ones" {
    const console_log = ziggy_log.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(1, false, console_log);
    defer fixture.deinit(timer_list.interface());
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "running", "wait-for-cancel", "gone", "null", .background, null);
    // The worker is started for the first task, which it runs once it reports it is ready.
    while (fixture.pool.pending_tasks.items.len > 0) {
        const message = fixture.queue.take(std.testing.io, std.testing.allocator, .none).?;
        defer std.testing.allocator.free(message.text);
        _ = fixture.receive(timer_list.interface(), message);
    }
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "waiting", "echo", "gone", "null", .background, null);
    fixture.pool.cancelSource(std.testing.io, std.testing.allocator, console_log, "gone");
    fixture.takeNotices();
    try std.testing.expect(fixture.indexOf("end|waiting|echo|cancelled|started=false") != null);
    try fixture.waitFor(timer_list.interface(), "end|running|wait-for-cancel|cancelled|started=true");
}

test "cancelling a task that waits on a child stops the child, and then the task" {
    const console_log = ziggy_log.mute_log.MuteLog.init();
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(2, false, console_log);
    defer fixture.deinit(timer_list.interface());
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "p1", "parent-of-waiter", "family", "null", .background, null);
    // The child is running once a second worker has been started for it and has taken it.
    while (fixture.pool.pending_tasks.items.len > 0 or fixture.pool.workers.items.len < 2) {
        const message = fixture.queue.take(std.testing.io, std.testing.allocator, .none).?;
        defer std.testing.allocator.free(message.text);
        _ = fixture.receive(timer_list.interface(), message);
    }
    fixture.pool.cancelSource(std.testing.io, std.testing.allocator, console_log, "family");
    fixture.takeNotices();
    try fixture.waitFor(timer_list.interface(), "end|p1|parent-of-waiter|cancelled");
    const child = fixture.indexOf("end|p1.c0|wait-for-cancel|cancelled") orelse return error.NotSeen;
    const parent = fixture.indexOf("end|p1|parent-of-waiter|cancelled") orelse return error.NotSeen;
    try std.testing.expect(child < parent);
}

test "shutting the pool down stops the tasks still running and ends every worker" {
    const console_log = ziggy_log.mute_log.MuteLog.init();
    // The testing allocator fails the test if a worker or a task is left unfreed, and shutdown returns only once every worker's
    // thread has ended.
    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(3, false, console_log);
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "a", "wait-for-cancel", "a", "null", .background, null);
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "b", "wait-for-cancel", "b", "null", .background, null);
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "c", "echo", "c", "null", .background, null);
    while (fixture.pool.workers.items.len < 2) {
        const message = fixture.queue.take(std.testing.io, std.testing.allocator, .none).?;
        defer std.testing.allocator.free(message.text);
        _ = fixture.receive(timer_list.interface(), message);
    }
    fixture.deinit(timer_list.interface());
}

test "a worker that cannot start reports why and ends, and the pool logs it and lets it go, leaving its task waiting" {
    const memory = try ziggy_log.memory_log.MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    // The test generator of uuids keeps its counter in TEST_TMP_DIR. Below a file that directory cannot be made, so a worker that
    // has to make its own session id cannot start.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "file",
        .data = "x",
    });
    const test_tmp_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/file/tmp", .{&tmp.sub_path});
    defer allocator.free(test_tmp_dir);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("NODE_ENV", "testing");
    try environment.put("TEST_TMP_DIR", test_tmp_dir);
    utils.process_env.setEnvironMap(&environment);
    defer utils.process_env.setEnvironMap(null);

    var timer_list = TimerList.init();
    var fixture: Fixture = undefined;
    fixture.init(1, false, memory.log);
    defer fixture.deinit(timer_list.interface());
    // No session id, so the worker makes its own.
    fixture.pool.options.worker_options.sessionId = "";
    try fixture.pool.addTask(std.testing.io, std.testing.allocator, fixture.log, "t1", "echo", "s", "null", .background, null);
    // A worker that cannot start is followed by another for the waiting task, which cannot start either, so messages keep coming and
    // the wait has a deadline of its own.
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromMilliseconds(10_000),
        .clock = .awake,
    });
    while (std.mem.indexOf(u8, memory.stderr(), "Worker 1 could not start: ") == null) {
        const message = fixture.queue.take(std.testing.io, std.testing.allocator, .{ .deadline = deadline }) orelse return error.TimedOut;
        defer std.testing.allocator.free(message.text);
        _ = fixture.receive(timer_list.interface(), message);
    }

    // The worker that could not start is gone, and the task has not run.
    for (fixture.pool.workers.items) |state| {
        try std.testing.expect(state.workerId != 1);
    }
    try std.testing.expect(fixture.indexOf("end|t1") == null);
}

//
// A log that keeps the last error line it was given.
//
const LastErrorLog = struct {
    // The last error line, in a buffer of its own.
    buffer: [256]u8 = undefined,
    // How much of the buffer the last error line fills.
    length: usize = 0,

    //
    // Gets the ILog interface for this log.
    //
    fn ilog(self: *LastErrorLog) ziggy_log.log.ILog {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The ILog functions of this log: only an error line is kept.
    //
    const vtable: ziggy_log.log.ILog.VTable = .{
        .info = ignore,
        .verbose = ignore,
        .@"error" = keepError,
        .exception = ignoreException,
        .warn = ignore,
        .debug = ignore,
        .tool = ignoreTool,
        .event = ignore,
        .verboseEnabled = never,
        .getLogDetails = noDetails,
        .logFilePath = noLogFilePath,
    };

    fn ignore(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        _ = message;
    }

    fn keepError(ptr: *anyopaque, message: []const u8) void {
        const self: *LastErrorLog = @ptrCast(@alignCast(ptr));
        @memcpy(self.buffer[0..message.len], message);
        self.length = message.len;
    }

    fn ignoreException(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        _ = ptr;
        _ = message;
        _ = err catch {};
    }

    fn ignoreTool(ptr: *anyopaque, tool_name: []const u8, data: ziggy_log.log.IToolOutput) void {
        _ = ptr;
        _ = tool_name;
        _ = data;
    }

    fn never(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }

    fn noDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!ziggy_log.log.ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return ziggy_log.log.noLogDetails;
    }

    fn noLogFilePath(ptr: *anyopaque) ?[]const u8 {
        _ = ptr;
        return null;
    }
};

test "writeTaggedLine gives a log the line with its source in front, and an exception as one error line with its cause" {
    var last_error: LastErrorLog = .{};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    ziggy.worker_pool.writeTaggedLine(arena_state.allocator(), last_error.ilog(), "Worker 4", .{
        .level = .exception,
        .message = "failed",
        .error_text = "Error: Boom",
        .tool_output = null,
    });
    try std.testing.expectEqualStrings("[Worker 4] failed\nError: Boom", last_error.buffer[0..last_error.length]);
}

