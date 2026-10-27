//
// Mock queue backend for testing TaskQueue.
// Runs tasks on real workers (see worker.zig in Ziggy's core) that talk to the pool by message, as the app's own pool does, with no
// native app and no frontend. The thread that makes the pool is its main thread: the pool reads the workers' messages on it, while a
// TaskQueue on that thread waits for its tasks.
// Exported from the package (task_queue_zig.mock_worker_pool) so other packages can test code that
// uses TaskQueue.
//

const std = @import("std");
const types = @import("types.zig");
const queue_backend = @import("queue-backend.zig");
const message_queue = @import("../message-queue.zig");
const worker_pool = @import("../worker-pool.zig");
const task_runner = @import("../task-runner.zig");
const app = @import("../app.zig");
const utils = @import("utils.zig");
const IQueueBackend = queue_backend.IQueueBackend;
const Timers = @import("../timers.zig").Timers;
const errors = utils.errors;
const ILog = utils.log.ILog;

//
// The parts of the task context shared by every task.
//
pub const IBaseContext = struct {
    // Unique identifier for the session the tasks belong to.
    sessionId: []const u8,

    // How many child tasks a task may have running at once.
    maxConcurrentChildTasks: u32 = 2,
};

//
// The task types of a mock pool, from a struct literal whose fields are task types and their handlers, as an app's `.tasks` gives
// them (see App in Ziggy's core). A handler is Ziggy's or one written against the task queue package.
//
pub fn handlers(comptime tasks: anytype) []const task_runner.TaskHandlerEntry {
    return comptime app.taskTable(tasks);
}
//
// Mock implementation of IQueueBackend that executes tasks on workers.
// Supports concurrency limits for testing parallel-execution scenarios: maxConcurrent is the number of workers.
// It keeps no Io or allocator: each function is given those of the thread that owns the pool, and what it keeps is allocated
// with that thread's allocator. Each worker makes its own.
//
pub const MockWorkerPool = struct {
    // The queue the workers send their messages to.
    queue: message_queue.MessageQueue,

    // The pool of workers.
    pool: worker_pool.WorkerPool,

    //
    // Creates the pool, allocated with the owning thread's allocator. No worker starts until a task is added.
    //
    pub fn init(allocator: std.mem.Allocator, maxConcurrent: usize, baseContext: IBaseContext, taskTypes: []const task_runner.TaskHandlerEntry) !*MockWorkerPool {
        const self = try allocator.create(MockWorkerPool);
        self.queue = message_queue.MessageQueue.init();
        self.pool = worker_pool.WorkerPool.init(&self.queue, .{
            .max_workers = @intCast(maxConcurrent),
            .tasks = taskTypes,
            .describe_error = describeError,
            .worker_options = .{
                .workerId = 0,
                .sessionId = baseContext.sessionId,
                .maxConcurrentChildTasks = baseContext.maxConcurrentChildTasks,
            },
        });
        return self;
    }

    //
    // Waits for the queued and running tasks to finish, running the owning thread's timers as they come due, stops the workers and frees
    // the pool.
    //
    pub fn deinit(self: *MockWorkerPool, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog) void {
        while (self.pool.isBusy()) {
            self.waitForMessage(io, allocator, timers, log);
        }
        self.pool.shutdown(io, allocator, timers, log, null);
        self.queue.deinit();
        allocator.destroy(self);
    }

    //
    // Gets the IQueueBackend interface for this pool.
    //
    pub fn queueBackend(self: *MockWorkerPool) IQueueBackend {
        return self.pool.queueBackend();
    }

    //
    // Reads the next message a worker sent and handles it, or runs the owning thread's timers that are due when one comes due first.
    //
    pub fn waitForMessage(self: *MockWorkerPool, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog) void {
        self.pool.waitForWorkerMessage(io, allocator, timers, log);
    }

    //
    // Handles every message the workers have sent so far, without waiting for more.
    //
    pub fn handleQueuedMessages(self: *MockWorkerPool, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog) void {
        while (self.queue.tryTake(io, allocator)) |message| {
            defer allocator.free(message.text);
            if (!self.pool.receive(io, allocator, timers, log, message)) {
                std.debug.panic("a message reached the mock worker pool from no worker of it: {s}", .{message.text});
            }
        }
    }

    //
    // The types of the tasks still waiting for a worker, in the order they will be dispatched.
    //
    pub fn getPendingTaskTypes(self: *MockWorkerPool, allocator: std.mem.Allocator) ![]const []const u8 {
        const taskTypes = try allocator.alloc([]const u8, self.pool.pending_tasks.items.len);
        for (self.pool.pending_tasks.items, taskTypes) |task, *taskType| {
            taskType.* = try allocator.dupe(u8, task.task_type);
        }
        return taskTypes;
    }

    //
    // Marks the source as cancelled: drops its pending tasks and tells the running ones to stop.
    //
    pub fn cancelTasks(self: *MockWorkerPool, io: std.Io, allocator: std.mem.Allocator, log: ILog, source: []const u8) void {
        self.pool.cancelSource(io, allocator, log, source);
    }
};

//
// Gives the text of a failed task's error: the message the handler recorded (the task queue's throwError), or the error's name.
//
fn describeError(err: anyerror) ?[]const u8 {
    const message = errors.errorMessage(err);
    if (message.len == 0) {
        return null;
    }
    return message;
}
